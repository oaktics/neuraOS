import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,symlink,rm,realpath} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import {Store} from '../../apps/daemon/src/store.ts';
import {Agents} from '../../apps/daemon/src/agents.ts';
import {CodexRPC,type RPCEvent} from '../../apps/daemon/src/codex-rpc.ts';
import type {Workspace} from '../../apps/daemon/src/contracts.ts';

function fixture(reportedCwd?:string){
  const store=new Store(':memory:');
  const workspace:Workspace={id:randomUUID(),projectId:randomUUID(),name:'worker',path:'/tmp/worker',branch:'test',kind:'worktree',createdAt:''};store.put('workspaces',workspace);
  const clients:{emit:(e:RPCEvent)=>void;calls:{method:string;params:any}[];replies:any[];failStart:boolean}[]=[];
  const factory:typeof CodexRPC.start=async(_program,_env,_args,emit)=>{
    const client={emit,calls:[] as {method:string;params:any}[],replies:[] as any[],failStart:false};clients.push(client);
    return {endpoint:'unix:///tmp/fake',pid:999999,
      async call(method:string,params:any){client.calls.push({method,params});
        if(method==='thread/start'||method==='thread/resume')return {thread:{id:params.threadId??randomUUID(),cwd:reportedCwd??workspace.path,status:{type:'idle'}}};
        if(method==='thread/loaded/list')return {data:[],nextCursor:null};
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
    assert.equal(recovered.get(main).pending.length,1);assert.equal(recovered.get(main).pending[0].report,true);
    assert.equal(recovered.get(main).status,'interrupted');
    const twice=new Agents(f.store,()=>'', '',f.factory);assert.equal(twice.get(main).pending.length,1);
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
