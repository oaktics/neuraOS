import {codexSessionInstructions} from '../../apps/daemon/src/session-instructions.ts';
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,symlink,rm,realpath} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import {Store} from '../../apps/daemon/src/store.ts';
import {Agents} from '../../apps/daemon/src/agents.ts';
import {CodexRPC,type RPCEvent} from '../../apps/daemon/src/codex-rpc.ts';
import type {Workspace} from '../../apps/daemon/src/contracts.ts';

function fixture(reportedCwd?:string,loadedId?:string){
  const store=new Store(':memory:');
  const workspace:Workspace={id:randomUUID(),projectId:randomUUID(),name:'worker',path:'/tmp/worker',branch:'test',kind:'worktree',createdAt:''};store.put('workspaces',workspace);
  const clients:{emit:(e:RPCEvent)=>void;calls:{method:string;params:any}[];replies:any[];failStart:boolean;args:string[]}[]=[];
  const factory:typeof CodexRPC.start=async(_program,_env,_args,emit)=>{
    const client={emit,calls:[] as {method:string;params:any}[],replies:[] as any[],failStart:false,args:_args};clients.push(client);
    return {endpoint:'unix:///tmp/fake',pid:999999,
      async call(method:string,params:any){client.calls.push({method,params});
        if(method==='thread/start'||method==='thread/resume')return {thread:{id:params.threadId??randomUUID(),cwd:reportedCwd??workspace.path,status:{type:'idle'}}};
        if(method==='thread/loaded/list')return {data:loadedId?[loadedId]:[],nextCursor:null};
        if(method==='thread/read')return {thread:{id:params.threadId,cwd:reportedCwd??workspace.path,status:{type:'idle'}}};
        if(method==='thread/turns/list')return {data:[{id:'history',items:[{type:'agentMessage',text:'result'}]}],nextCursor:null};
        if(method==='turn/start'){
          if(client.failStart)throw new Error('timeout');
          const turn={id:randomUUID()};emit({method:'turn/started',params:{threadId:params.threadId,turn}});return {turn};
        }
        return {};
      },reply(id:unknown,result:unknown){client.replies.push({id,result});},signal(){},async close(){emit({method:'neura/disconnected'});},
    } as unknown as CodexRPC;
  };
  const agents=new Agents(store,()=> 'http://127.0.0.1:4318','/tmp/token',factory);
  const open=()=>agents.open('fake',{},workspace,randomUUID());
  return {store,workspace,agents,clients,open,factory};
}
const tick=()=>new Promise(r=>setImmediate(r));
function confirmClaudeChannel(agents:Agents,terminalId:string){
  const probe=agents.channel(terminalId);assert.equal(probe.meta?.kind,'probe');
  const nonce=probe.content!.match(/nonce ([a-f0-9-]{36})/)![1];agents.acknowledgeChannel(terminalId,nonce);
  const a=agents.list().find(a=>a.terminalId===terminalId&&a.provider==='claude')!;
  agents.claudeEvent(terminalId,{hook_event_name:'Stop',session_id:a.id,transcript_path:a.transcriptPath});
}


test('a later supervisor discovers existing independent sessions and reads the exact conversation',async()=>{
  const f=fixture();try{
    const worker=await f.open(),main=await f.open();
    assert.equal(f.agents.list().length,2);assert.notEqual(worker.threadId,main.threadId);
    const {history}=await f.agents.read(worker.threadId!);assert.equal(history.data[0].id,'history');
    assert.equal(f.clients[0].calls.at(-1)!.params.threadId,worker.threadId);
    assert.equal(f.clients[1].calls.some(c=>c.method==='thread/turns/list'),false);
  }finally{await f.agents.shutdown();f.store.close();}
});

test('queued instructions wait for completion; steering and interrupts reject stale turn IDs',async()=>{
  const f=fixture();try{
    const {threadId:id}=await f.open();await f.agents.send(id!,'first','queue');
    const first=f.agents.get(id!).turnId!;
    await f.agents.send(id!,'second','queue');assert.equal(f.agents.get(id!).pending.length,1);
    assert.equal(f.clients[0].calls.filter(c=>c.method==='turn/start').length,1);
    await assert.rejects(f.agents.send(id!,'stale','steer',randomUUID()),/変わりました/);
    await f.agents.send(id!,'correct','steer',first);
    assert.equal(f.clients[0].calls.at(-1)!.params.expectedTurnId,first);
    f.clients[0].emit({method:'turn/completed',params:{threadId:id,turn:{id:first,status:'completed'}}});await tick();
    assert.equal(f.clients[0].calls.filter(c=>c.method==='turn/start').length,2);
    assert.equal(f.agents.get(id!).pending.length,0);
    const second=f.agents.get(id!).turnId!;assert.notEqual(first,second);
    await assert.rejects(f.agents.interrupt(id!,first),/変わりました/);
    await f.agents.send(id!,'third','queue');await f.agents.interrupt(id!,second);
    assert.equal(f.agents.get(id!).pending.length,0);
  }finally{await f.agents.shutdown();f.store.close();}
});

test('uncertain dispatch is never replayed and persisted sessions recover as interrupted',async()=>{
  const f=fixture();try{
    const {threadId:id}=await f.open();f.clients[0].failStart=true;
    await assert.rejects(f.agents.send(id!,'do once','queue'),/timeout/);
    assert.equal(f.agents.get(id!).status,'interrupted');assert.equal(f.agents.get(id!).pending.length,0);
    await f.agents.shutdown();
    const restarted=new Agents(f.store,()=>'', '',f.factory);
    assert.equal(restarted.get(id!).status,'interrupted');
    await assert.rejects(restarted.send(id!,'offline','queue'),/停止/);
    await restarted.shutdown();
  }finally{await f.agents.shutdown();f.store.close();}
});

test('a pending question is addressed by exact request ID and stale answers are rejected',async()=>{
  const f=fixture();try{
    const {threadId:id}=await f.open();
    f.clients[0].emit({method:'item/tool/requestUserInput',id:42,params:{threadId:id,questions:[]}});
    assert.equal(f.agents.get(id!).status,'waiting');
    assert.throws(()=>f.agents.respond(id!,43,{}),/終了/);
    f.agents.respond(id!,42,{answers:{q:{answers:['yes']}}});
    assert.equal(f.clients[0].replies.length,1);assert.equal(f.agents.get(id!).requests.length,0);
    assert.throws(()=>f.agents.respond(id!,42,{}),/終了/);
  }finally{await f.agents.shutdown();f.store.close();}
});

test('resume rejects a different workspace and a running session; deletion removes registry entries',async()=>{
  const f=fixture();try{
    const {threadId:id}=await f.open();
    await assert.rejects(f.agents.open('fake',{},f.workspace,randomUUID(),id),/実行中/);
    await assert.rejects(f.agents.open('fake',{}, {...f.workspace,id:randomUUID()},randomUUID(),id),/別の作業/);
    await f.agents.shutdown();f.store.deleteWorkspace(f.workspace.id);
    assert.equal(f.agents.list().length,0);
    f.clients[0].emit({method:'thread/started',params:{thread:{id,cwd:f.workspace.path}}});assert.equal(f.agents.list().length,0);
  }finally{await f.agents.shutdown();f.store.close();}
});

test('one-shot watches wake an idle supervisor with tool output, without cycles or duplicate delivery',async()=>{
  const f=fixture();try{
    const worker=(await f.open()).threadId!,main=(await f.open()).threadId!;
    f.agents.watch(main,[worker]);assert.throws(()=>f.agents.watch(worker,[main]),/循環/);
    await f.agents.send(worker,'work','queue');const turn=f.agents.get(worker).turnId!;
    f.clients[0].emit({method:'item/completed',params:{threadId:worker,item:{type:'agentMessage',text:'Tests passed'}}});
    f.clients[0].emit({method:'turn/completed',params:{threadId:worker,turn:{id:turn,status:'completed'}}});await tick();
    const calls=f.clients[1].calls.filter(c=>c.method==='turn/start');assert.equal(calls.length,1);
    assert.deepEqual(calls[0].params.input,[]);assert.equal(calls[0].params.toolOutput.name,'neuraos_task_event');
    assert.match(calls[0].params.toolOutput.output,/Tests passed/);assert.equal(f.agents.get(main).watching?.length,0);
    f.clients[0].emit({method:'turn/completed',params:{threadId:worker,turn:{id:turn,status:'completed'}}});await tick();
    assert.equal(f.clients[1].calls.filter(c=>c.method==='turn/start').length,1);
  }finally{await f.agents.shutdown();f.store.close();}
});

test('a completion saved before a crash is delivered once on recovery without running an offline supervisor',async()=>{
  const f=fixture();try{
    const worker=(await f.open()).threadId!,main=(await f.open()).threadId!;
    f.agents.watch(main,[worker]);await f.agents.shutdown();
    f.store.put('agents',{...f.agents.get(worker),lastTurnId:randomUUID(),lastTurnStatus:'completed',summary:'Recovered report'});
    const recovered=new Agents(f.store,()=>'', '',f.factory);
    assert.equal(recovered.get(main).pending.length,0);assert.equal(recovered.get(main).reports?.length,1);
    assert.equal(recovered.get(main).status,'interrupted');
    const twice=new Agents(f.store,()=>'', '',f.factory);assert.equal(twice.get(main).reports?.length,1);
    await recovered.shutdown();await twice.shutdown();
  }finally{await f.agents.shutdown();f.store.close();}
});

test('a new failed turn never reports the previous turn summary',async()=>{
  const f=fixture();try{
    const worker=(await f.open()).threadId!,main=(await f.open()).threadId!;
    await f.agents.send(worker,'first','queue');let turn=f.agents.get(worker).turnId!;
    f.clients[0].emit({method:'item/completed',params:{threadId:worker,turnId:turn,item:{type:'agentMessage',text:'Old tests passed'}}});
    f.clients[0].emit({method:'turn/completed',params:{threadId:worker,turn:{id:turn,status:'completed'}}});
    f.agents.watch(main,[worker]);await f.agents.send(worker,'second','queue');turn=f.agents.get(worker).turnId!;
    assert.equal(f.agents.get(worker).summary,undefined);
    f.clients[0].emit({method:'turn/completed',params:{threadId:worker,turn:{id:turn,status:'failed'}}});await tick();
    const report=f.clients[1].calls.find(c=>c.method==='turn/start')!.params.toolOutput.output;
    assert.doesNotMatch(report,/Old tests passed/);assert.match(report,/failed/);
  }finally{await f.agents.shutdown();f.store.close();}
});


test('cold resume accepts the same workspace through its canonical filesystem path',async()=>{
  const root=await mkdtemp('/tmp/neura-alias-test-');await symlink(root,root+'-alias');
  const f=fixture(await realpath(root));f.workspace.path=root+'-alias';f.store.put('workspaces',f.workspace);
  try{
    const id=(await f.open()).threadId!;await f.agents.shutdown();
    const restarted=new Agents(f.store,()=>'', '',f.factory);
    assert.equal((await restarted.open('fake',{},f.workspace,randomUUID(),id)).threadId,id);
    await restarted.shutdown();
  }finally{await f.agents.shutdown();f.store.close();await rm(root+'-alias');await rm(root,{recursive:true,force:true});}
});

test('history selection in another terminal cannot take over a live session',async()=>{
  const f=fixture();try{
    const worker=(await f.open()).threadId!,second=(await f.open()).threadId!;
    await f.agents.send(worker,'original work','queue');const owner=f.agents.get(worker);
    f.clients[1].emit({method:'thread/started',params:{thread:{id:worker,cwd:f.workspace.path,status:{type:'idle'}}}});await tick();
    assert.equal(f.agents.get(worker).terminalId,owner.terminalId);
    assert.equal(f.agents.get(worker).turnId,owner.turnId);
    await assert.rejects(f.agents.send(second,'must not run','queue'),/停止/);
    f.clients[0].emit({method:'turn/completed',params:{threadId:worker,turn:{id:owner.turnId,status:'completed'}}});
    assert.equal(f.agents.get(worker).lastTurnStatus,'completed');
    assert.equal(f.agents.get(worker).status,'idle');
  }finally{await f.agents.shutdown();f.store.close();}
});

for(const resume of [false,true])test(`shared workflow instructions reach Codex ${resume?'resume':'start'}`,async()=>{
  const f=fixture();try{
    const first=await f.open();
    if(resume){await f.agents.shutdown();await f.agents.open('fake',{},f.workspace,randomUUID(),first.threadId);}
    const call=f.clients.at(-1)!.calls.find(c=>c.method===(resume?'thread/resume':'thread/start'))!;
    assert.equal(call.params.developerInstructions,codexSessionInstructions);
    assert.ok(f.clients.at(-1)!.args.includes('developer_instructions='+JSON.stringify(codexSessionInstructions)));
    assert.match(call.params.developerInstructions,/Respect explicit user instructions/);
    assert.match(call.params.developerInstructions,/task_list/);
    assert.match(call.params.developerInstructions,/Isolate independent code changes in a worktree/);
  }finally{await f.agents.shutdown();f.store.close();}
});

test('history chooser discovery also installs shared workflow instructions',async()=>{
  const id=randomUUID(),f=fixture(undefined,id);
  try{
    const opened=await f.agents.open('fake',{},f.workspace,randomUUID(),undefined,undefined,true);
    assert.equal(opened.threadId,undefined);
    assert.ok(f.clients[0].args.includes('developer_instructions='+JSON.stringify(codexSessionInstructions)),'server config covers TUI-created threads before discovery');
    for(let i=0;i<150&&!f.agents.list().length;i++)await new Promise(r=>setTimeout(r,25));
    assert.equal(f.agents.get(id).id,id);
    const resume=f.clients[0].calls.find(c=>c.method==='thread/resume');
    assert.equal(resume?.params.developerInstructions,codexSessionInstructions);
  }finally{await f.agents.shutdown();f.store.close();}
});


test('active supervisor receives and acknowledges many reports without filling instruction queue',async()=>{
  const f=fixture();try{
    const id=(await f.open()).threadId!;await f.agents.send(id,'long-running work','queue');
    await f.agents.send(id,'do not discard this instruction','queue');
    const instructionId=f.agents.get(id).pending[0].id;
    for(let i=0;i<100;i++){
      const {reportId}=f.agents.report(id,`progress ${i}`);
      const {agent}=await f.agents.read(id);assert.equal(agent.reports?.[0].id,reportId);
      f.agents.ack(id,[reportId,instructionId]);
      assert.equal(f.agents.get(id).pending[0].id,instructionId);
      assert.equal(f.agents.get(id).reports?.length,0);
    }
    assert.equal(f.clients[0].calls.filter(c=>c.method==='turn/start').length,1);
    for(let i=1;i<32;i++)await f.agents.send(id,`instruction ${i}`,'queue');
    await assert.rejects(f.agents.send(id,'overflow instruction','queue'),{code:'agent_queue_full'});
    const {reportId}=f.agents.report(id,'report still accepted with 32 queued instructions');
    f.agents.ack(id,[reportId]);assert.equal(f.agents.get(id).pending.length,32);
    assert.throws(()=>f.agents.report(id,'x'.repeat(16385)),{code:'invalid_report'});
  }finally{await f.agents.shutdown();f.store.close();}
});

test('report notification does not restart forever when the receiver completes without acknowledging',async()=>{
  const f=fixture();try{
    const id=(await f.open()).threadId!;
    const {reportId}=f.agents.report(id,'done');await tick();
    const turn=f.agents.get(id).turnId!;
    f.clients[0].emit({method:'turn/completed',params:{threadId:id,turn:{id:turn,status:'completed'}}});await tick();
    assert.equal(f.clients[0].calls.filter(c=>c.method==='turn/start').length,1);
    assert.equal(f.agents.get(id).reports?.[0].id,reportId);
    assert.equal(f.agents.get(id).reports?.[0].notified,true);
    f.agents.ack(id,[reportId]);await tick();
    assert.equal(f.clients[0].calls.filter(c=>c.method==='turn/start').length,1);
  }finally{await f.agents.shutdown();f.store.close();}
});

test('full report inbox preserves watches and delivers after ack without deleting execution instructions',async()=>{
  const f=fixture();try{
    const worker=(await f.open()).threadId!,main=(await f.open()).threadId!;
    await f.agents.send(main,'active','queue');
    for(let i=0;i<32;i++)f.agents.report(main,`report ${i}`);
    assert.throws(()=>f.agents.report(main,'overflow'),{code:'agent_reports_full'});
    await f.agents.send(main,'instruction still fits','queue');
    f.agents.watch(main,[worker]);await f.agents.send(worker,'work','queue');
    f.clients[0].emit({method:'item/completed',params:{threadId:worker,item:{type:'agentMessage',text:'completion evidence'}}});
    f.clients[0].emit({method:'turn/completed',params:{threadId:worker,turn:{id:f.agents.get(worker).turnId,status:'completed'}}});await tick();
    assert.equal(f.agents.get(main).watching?.length,1);
    await f.agents.send(worker,'next turn clears summary','queue');
    const report=f.agents.get(main).reports![0];f.agents.ack(main,[report.id]);
    assert.equal(f.agents.get(main).watching?.length,0);
    assert.equal(f.agents.get(main).reports?.length,32);
    assert.equal(f.agents.get(main).reports?.at(-1)?.sourceTaskId,worker);
    assert.match(f.agents.get(main).reports!.at(-1)!.text,/completion evidence/);
    assert.equal(f.agents.get(main).pending[0].text,'instruction still fits');
  }finally{await f.agents.shutdown();f.store.close();}
});

test('watch updates coalesce by worker and stale acknowledgments never erase a new report',async()=>{
  const f=fixture();try{
    const worker=(await f.open()).threadId!,main=(await f.open()).threadId!;
    await f.agents.send(main,'active','queue');let oldId='';
    for(let i=0;i<50;i++){
      f.agents.watch(main,[worker]);await f.agents.send(worker,`work ${i}`,'queue');
      f.clients[0].emit({method:'turn/completed',params:{threadId:worker,turn:{id:f.agents.get(worker).turnId,status:'completed'}}});await tick();
      const report=f.agents.get(main).reports![0];assert.notEqual(report.id,oldId);
      f.agents.ack(main,[oldId]);assert.equal(f.agents.get(main).reports![0].id,report.id);oldId=report.id;
    }
    assert.equal(f.agents.get(main).reports?.length,1);
    assert.equal(f.agents.get(main).reports?.[0].updates,50);
    assert.equal(f.agents.get(main).pending.length,0);
  }finally{await f.agents.shutdown();f.store.close();}
});

test('legacy watch reports migrate in bounded batches while old send instructions remain untouched',async()=>{
  const f=fixture();try{
    const id=(await f.open()).threadId!;await f.agents.shutdown();
    const instruction={id:randomUUID(),text:'old progress indistinguishable from an instruction'};
    const legacy=Array.from({length:40},()=>({id:randomUUID(),text:'old report',report:true}));
    f.store.put('agents',{...f.agents.get(id),pending:[instruction,...legacy]});
    const recovered=new Agents(f.store,()=>'', '',f.factory);
    assert.equal(recovered.get(id).reports?.length,32);assert.equal(recovered.get(id).pending.length,9);
    recovered.ack(id,recovered.get(id).reports!.map(r=>r.id));
    assert.equal(recovered.get(id).reports?.length,8);assert.deepEqual(recovered.get(id).pending,[instruction]);
    recovered.ack(id,[instruction.id,...legacy.map(r=>r.id)]);
    assert.equal(recovered.get(id).reports?.length,0);assert.deepEqual(recovered.get(id).pending,[instruction]);
    await recovered.shutdown();
  }finally{await f.agents.shutdown();f.store.close();}
});

test('Codex name notifications update the exact tab and worktree but preserve manual worktree names',async()=>{
  const f=fixture();try{
    const {threadId:id}=await f.open(),agent=f.agents.get(id!);
    f.store.put('terminals',{id:agent.terminalId,workspaceId:f.workspace.id,provider:'codex',status:'running',sessionId:id,cols:80,rows:24,createdAt:''});
    const rename=(name:string)=>f.clients[0].emit({method:'thread/name/updated',params:{threadId:id,threadName:name}});
    rename('生成されたタイトル');
    assert.equal(f.store.get<Workspace>('workspaces',f.workspace.id)?.name,'生成されたタイトル');
    assert.equal(f.store.get<any>('terminals',agent.terminalId)?.sessionName,'生成されたタイトル');
    f.store.put('workspaces',{...f.workspace,name:'Manual',nameSource:'manual'});
    rename('更新されたタイトル');assert.equal(f.store.get<Workspace>('workspaces',f.workspace.id)?.name,'Manual');
    f.store.put('workspaces',f.workspace);
    f.store.put('terminals',{...f.store.get<any>('terminals',agent.terminalId),sessionId:'another'});
    rename('古いセッション');assert.equal(f.store.get<Workspace>('workspaces',f.workspace.id)?.name,f.workspace.name);
    f.clients[0].emit({method:'thread/started',params:{thread:{id:'temporary',cwd:f.workspace.path,ephemeral:true}}});
    assert.equal(f.agents.list().length,1);
  }finally{await f.agents.shutdown();f.store.close();}
});


test('manual report attribution uses the current terminal task, not an older thread sharing that terminal',async()=>{
  const f=fixture();try{
    const old=(await f.open()).threadId!,main=(await f.open()).threadId!;
    await f.agents.send(main,'active','queue');
    const terminalId=f.agents.get(old).terminalId,currentId=randomUUID();
    f.store.put('agents',{...f.agents.get(old),id:currentId});
    f.store.put('terminals',{id:terminalId,workspaceId:f.workspace.id,provider:'codex',status:'running',agentId:currentId,sessionId:currentId,cols:80,rows:24,createdAt:''});
    f.agents.report(main,'current task report',terminalId);
    assert.equal(f.agents.get(main).reports?.[0].sourceTaskId,currentId);
  }finally{await f.agents.shutdown();f.store.close();}
});

test('Claude and Codex supervise each other with exact reports, compact safety, recovery and no stale-session delivery',async()=>{
  const f=fixture(),terminalId=randomUUID(),id=randomUUID(),path='/tmp/claude.jsonl';let interrupted=0;
  const event=(hook_event_name:string,extra:Record<string,string>={})=>f.agents.claudeEvent(terminalId,{hook_event_name,session_id:id,transcript_path:path,...extra});
  try{
    f.agents.prepareClaude(f.workspace,terminalId,undefined,undefined,()=>interrupted++);
    event('SessionStart',{source:'startup'});confirmClaudeChannel(f.agents,terminalId);
    const codex=(await f.open()).threadId!;
    f.agents.watch(codex,[id]);await f.agents.send(id,'Claude work','queue');
    assert.equal(f.agents.channel(terminalId).content,'Claude work');const first=f.agents.get(id).turnId;
    await f.agents.send(id,'queued during compact','queue');event('SessionStart',{source:'compact'});
    assert.equal(f.agents.get(id).turnId,first);assert.equal(f.agents.get(id).status,'working');assert.deepEqual(f.agents.channel(terminalId),{});
    event('Stop',{last_assistant_message:'Claude completed'});await tick();
    assert.equal(f.clients[0].calls.filter(c=>c.method==='turn/start').length,1);
    event('Stop');await tick();assert.equal(f.clients[0].calls.filter(c=>c.method==='turn/start').length,1);
    assert.equal(f.agents.channel(terminalId).content,'queued during compact');event('StopFailure');
    await f.agents.send(id,'retry failed','queue');assert.equal(f.agents.channel(terminalId).content,'retry failed');
    await f.agents.interrupt(id,f.agents.get(id).turnId!);assert.equal(interrupted,1);
    await f.agents.send(id,'retry interrupted','queue');assert.equal(f.agents.channel(terminalId).content,'retry interrupted');event('Stop');
    f.agents.watch(id,[codex]);
    const turn=f.agents.get(codex).turnId!;f.clients[0].emit({method:'turn/completed',params:{threadId:codex,turn:{id:turn,status:'completed'}}});await tick();
    const notification=f.agents.channel(terminalId);assert.equal(notification.meta?.kind,'reports');const reports=f.agents.get(id).reports!;
    assert.equal(reports.length,1);f.agents.ack(id,[reports[0].id]);event('Stop');assert.deepEqual(f.agents.channel(terminalId),{});
    await f.agents.send(id,'must remain after end','queue');event('SessionEnd');assert.deepEqual(f.agents.channel(terminalId),{});
    await assert.rejects(f.agents.send(id,'offline','queue'),/停止/);
    const next=randomUUID();event('SessionStart',{session_id:next,source:'clear',transcript_path:'/tmp/next.jsonl'});
    assert.deepEqual(f.agents.channel(terminalId),{});assert.equal(f.agents.get(id).pending.length,1);
    await assert.rejects(f.agents.send(id,'old','queue'),/別の会話/);
    await f.agents.close(terminalId);assert.throws(()=>f.agents.channel(terminalId),/停止/);
  }finally{await f.agents.shutdown();f.store.close();}
});

test('Claude resume validates provider/workspace and never transfers a live identity to another terminal',async()=>{
  const f=fixture(),t=randomUUID(),id=randomUUID();let rejected=0;
  try{
    f.agents.prepareClaude(f.workspace,t,undefined,undefined,()=>{});f.agents.claudeEvent(t,{hook_event_name:'SessionStart',session_id:id,source:'startup'});
    assert.throws(()=>f.agents.prepareClaude(f.workspace,randomUUID(),id,undefined,()=>{}),/実行中/);
    const other=randomUUID();f.agents.prepareClaude(f.workspace,other,undefined,undefined,()=>rejected++);
    f.agents.claudeEvent(other,{hook_event_name:'SessionStart',session_id:id,source:'resume'});assert.equal(rejected,1);assert.equal(f.agents.get(id).terminalId,t);
    await f.agents.close(t);f.agents.prepareClaude(f.workspace,other,id,undefined,()=>{});
    f.agents.claudeEvent(other,{hook_event_name:'SessionStart',session_id:id,source:'resume'});assert.equal(f.agents.get(id).terminalId,other);
  }finally{await f.agents.shutdown();f.store.close();}
});

test('delegated Codex and Claude attach watches before first inference without replacing existing watches',async()=>{
  const f=fixture();
  try{
    const parent=(await f.open()).threadId!,existing=(await f.open()).threadId!;
    f.agents.watch(parent,[existing]);
    const codex=await f.agents.open('fake',{},f.workspace,randomUUID(),undefined,parent);
    assert.deepEqual(f.agents.get(parent).watching?.map(w=>w.taskId),[existing,codex.threadId]);
    await f.agents.send(codex.threadId!,'fast completion','queue');const turn=f.agents.get(codex.threadId!).turnId;
    f.clients[2].emit({method:'turn/completed',params:{threadId:codex.threadId,turn:{id:turn,status:'completed'}}});await tick();
    assert.equal(f.agents.get(parent).reports?.[0].sourceTaskId,codex.threadId);
    const terminal=randomUUID(),claude=randomUUID();
    f.agents.prepareClaude(f.workspace,terminal,undefined,parent,()=>{},'initial Claude instruction');
    assert.deepEqual(f.agents.channel(terminal),{});
    f.agents.claudeEvent(terminal,{hook_event_name:'SessionStart',session_id:claude,source:'startup'});
    assert.deepEqual(f.agents.get(parent).watching?.map(w=>w.taskId),[existing,claude]);
    confirmClaudeChannel(f.agents,terminal);assert.equal(f.agents.get(claude).lastTurnId,undefined,'probe is not worker completion');
    assert.equal(f.agents.channel(terminal).content,'initial Claude instruction');
    f.agents.claudeEvent(terminal,{hook_event_name:'Stop',session_id:claude});
    assert.ok(f.agents.get(parent).reports?.some(r=>r.sourceTaskId===claude));
  }finally{await f.agents.shutdown();f.store.close();}
});

test('MCP polling without a Channels listener leaves instructions queued and times out without claiming connected',async()=>{
  const f=fixture(),terminal=randomUUID(),id=randomUUID();
  try{
    f.agents.prepareClaude(f.workspace,terminal,undefined,undefined,()=>{},'keep queued');
    f.agents.claudeEvent(terminal,{hook_event_name:'SessionStart',source:'startup',session_id:id});
    const probe=f.agents.channel(terminal);assert.equal(probe.meta?.kind,'probe');
    assert.throws(()=>f.agents.acknowledgeChannel(terminal,randomUUID()),/一致/);
    assert.deepEqual(f.agents.channel(terminal),{});assert.equal(f.agents.get(id).pending[0].text,'keep queued');assert.equal(f.agents.get(id).status,'idle');
    const now=Date.now;try{Date.now=()=>now()+61000;assert.deepEqual(f.agents.channel(terminal),{});}finally{Date.now=now;}
    assert.equal(f.agents.get(id).channelState,'unavailable');assert.equal(f.agents.get(id).pending.length,1);assert.equal(f.agents.get(id).turnId,undefined);
  }finally{await f.agents.shutdown();f.store.close();}
});

test('manual Claude interruption only affects active work and stale Stop cannot finish the next turn',async()=>{
  const f=fixture(),terminal=randomUUID(),id=randomUUID();
  const event=(name:string,extra={})=>f.agents.claudeEvent(terminal,{hook_event_name:name,session_id:id,...extra});
  try{
    f.agents.prepareClaude(f.workspace,terminal,undefined,undefined,()=>{});event('SessionStart');confirmClaudeChannel(f.agents,terminal);
    f.agents.claudeInterrupted(terminal);assert.equal(f.agents.get(id).status,'idle','Esc in menus is not an interrupt');
    await f.agents.send(id,'first','queue');f.agents.channel(terminal);f.agents.claudeInterrupted(terminal);
    assert.equal(f.agents.get(id).status,'interrupted');assert.equal(f.agents.get(id).turnId,undefined);
    event('PostToolUse');assert.equal(f.agents.get(id).status,'interrupted');
    await f.agents.send(id,'second','queue');assert.equal(f.agents.channel(terminal).content,'second');const second=f.agents.get(id).turnId;
    event('Stop',{observed_at:String(Date.now()-10000)});assert.equal(f.agents.get(id).turnId,second);
    event('Stop',{assistant_timestamp:new Date(0).toISOString()});assert.equal(f.agents.get(id).turnId,second);
    event('Stop');assert.equal(f.agents.get(id).lastTurnId,second);
    await f.agents.send(id,'permission','queue');f.agents.channel(terminal);event('PermissionRequest');
    f.agents.claudeInterrupted(terminal);assert.equal(f.agents.get(id).status,'waiting','Esc may only dismiss a menu');
    f.agents.claudeInterrupted(terminal,true);assert.equal(f.agents.get(id).status,'interrupted','Ctrl-C cancels a waiting turn');
    await f.agents.send(id,'recover waiting','queue');assert.equal(f.agents.channel(terminal).content,'recover waiting');
  }finally{await f.agents.shutdown();f.store.close();}
});

test('clear/resume resets an unacknowledged probe without replaying old session instructions',async()=>{
  const f=fixture(),terminal=randomUUID(),old=randomUUID(),next=randomUUID();
  try{
    f.agents.prepareClaude(f.workspace,terminal,undefined,undefined,()=>{},'old instruction');
    f.agents.claudeEvent(terminal,{hook_event_name:'SessionStart',session_id:old});
    const first=f.agents.channel(terminal),firstNonce=first.content!.match(/nonce ([a-f0-9-]{36})/)![1];
    f.agents.claudeEvent(terminal,{hook_event_name:'SessionStart',source:'clear',session_id:next});
    const second=f.agents.channel(terminal),secondNonce=second.content!.match(/nonce ([a-f0-9-]{36})/)![1];
    assert.notEqual(secondNonce,firstNonce);assert.throws(()=>f.agents.acknowledgeChannel(terminal,firstNonce),/一致/);
    assert.equal(f.agents.get(old).pending[0].text,'old instruction');assert.deepEqual(f.agents.get(next).pending,[]);
    f.agents.claudeEvent(terminal,{hook_event_name:'UserPromptSubmit',session_id:next});f.agents.acknowledgeChannel(terminal,secondNonce);
    f.agents.claudeInterrupted(terminal);await f.agents.send(next,'new instruction','queue');assert.equal(f.agents.channel(terminal).content,'new instruction','interruption after ack clears probe Stop barrier');
  }finally{await f.agents.shutdown();f.store.close();}
});


test('Claude receipt probe waits for manual work to finish and preserves its completion report',async()=>{
  const f=fixture(),terminal=randomUUID(),id=randomUUID(),parentTerminal=randomUUID(),parent=randomUUID();
  const event=(name:string,extra={})=>f.agents.claudeEvent(terminal,{hook_event_name:name,session_id:id,...extra});
  try{
    f.agents.prepareClaude(f.workspace,parentTerminal,undefined,undefined,()=>{});
    f.agents.claudeEvent(parentTerminal,{hook_event_name:'SessionStart',session_id:parent});
    f.agents.prepareClaude(f.workspace,terminal,undefined,parent,()=>{});event('SessionStart');
    f.agents.watch(parent,[id]);
    event('UserPromptSubmit');const turn=f.agents.get(id).turnId;
    assert.deepEqual(f.agents.channel(terminal),{});
    event('PermissionRequest');assert.deepEqual(f.agents.channel(terminal),{});
    event('PostToolUse');assert.deepEqual(f.agents.channel(terminal),{});
    event('Stop',{last_assistant_message:'Manual work completed'});
    assert.equal(f.agents.get(id).lastTurnId,turn);
    assert.equal(f.agents.get(id).summary,'Manual work completed');
    assert.equal(f.agents.get(parent).reports?.length,1);
    assert.ok(f.agents.get(parent).reports?.[0].text.includes('Manual work completed'));
    confirmClaudeChannel(f.agents,terminal);
    assert.equal(f.agents.get(id).lastTurnId,turn);
    assert.equal(f.agents.get(parent).reports?.length,1);
  }finally{await f.agents.shutdown();f.store.close();}
});

test('lost Claude Stop hooks recover probe and work completion without replaying old turns',async()=>{
  const {writeFile}=await import('node:fs/promises');
  const root=await mkdtemp('/tmp/neura-lost-stop-'),path=root+'/session.jsonl',f=fixture(),terminal=randomUUID(),id=randomUUID();
  const event=(hook_event_name:string,extra={})=>f.agents.claudeEvent(terminal,{hook_event_name,session_id:id,transcript_path:path,...extra});
  const finish=async(text:string)=>{
    const timestamp=new Date().toISOString();
    await writeFile(path,[{type:'assistant',sessionId:id,timestamp,message:{content:[{type:'text',text}]}},{type:'system',subtype:'turn_duration',sessionId:id,timestamp}].map(r=>JSON.stringify(r)).join('\n')+'\n');
  };
  try{
    f.agents.prepareClaude(f.workspace,terminal,undefined,undefined,()=>{},'queued initial work');event('SessionStart');
    const probe=f.agents.channel(terminal),nonce=probe.content!.match(/nonce ([a-f0-9-]{36})/)![1];
    event('PreToolUse');f.agents.acknowledgeChannel(terminal,nonce);event('PostToolUse');
    await finish('Probe received');
    const recovered=await f.agents.claudeCompletion(terminal);assert.ok(recovered);f.agents.claudeEvent(terminal,recovered);
    assert.equal(f.agents.get(id).status,'idle');assert.equal(f.agents.get(id).lastTurnId,undefined);
    await new Promise(r=>setTimeout(r,5));
    assert.equal(f.agents.channel(terminal).content,'queued initial work');
    assert.equal(await f.agents.claudeCompletion(terminal),undefined,'probe completion cannot finish delegated work');
    await finish('Verified work');
    f.agents.report(id,'new worker result');
    const stop=await f.agents.claudeCompletion(terminal);assert.ok(stop);f.agents.claudeEvent(terminal,stop);
    assert.equal(f.agents.get(id).summary,'Verified work');assert.equal(f.agents.get(id).status,'idle');
    await new Promise(r=>setTimeout(r,5));
    assert.equal(f.agents.channel(terminal).meta?.kind,'reports');
    f.agents.claudeEvent(terminal,stop);
    assert.equal(f.agents.get(id).status,'working','delayed original Stop cannot complete the next notification');
    assert.equal(await f.agents.claudeCompletion(terminal),undefined);
    await f.agents.close(terminal);assert.equal(await f.agents.claudeCompletion(terminal),undefined);
  }finally{await f.agents.shutdown();f.store.close();await rm(root,{recursive:true,force:true});}
});

test('self-addressed worker reports are rejected with the supervisor recipient',async()=>{
  const f=fixture();try{
    const parent=(await f.open()).threadId!,child=(await f.open()).threadId!,a=f.agents.get(child);
    f.store.put('agents',{...a,parentTaskId:parent});
    f.store.put('terminals',{id:a.terminalId,agentId:child});
    assert.throws(()=>f.agents.report(child,'done',a.terminalId),{code:'report_to_self'});
    assert.equal(f.agents.get(child).reports?.length??0,0);
    f.agents.report(parent,'done',a.terminalId);assert.equal(f.agents.get(parent).reports?.[0].sourceTaskId,child);
  }finally{await f.agents.shutdown();f.store.close();}
});
