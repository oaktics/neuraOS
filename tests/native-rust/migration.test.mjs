import {test} from 'node:test';
import assert from 'node:assert/strict';
import {spawn,execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {mkdtemp,mkdir,readFile,writeFile,rm,realpath} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {createServer} from 'node:net';
import {randomUUID,createHash} from 'node:crypto';
import {DatabaseSync} from 'node:sqlite';
import {setTimeout as sleep} from 'node:timers/promises';
const exec=promisify(execFile),repository=resolve('.'),binary=resolve(process.env.NEURA_NATIVE_DAEMON??'crates/native-core/target/debug/neura-native-core');
const loader=import.meta.resolve('tsx');
const legacy=resolve('apps/daemon/src/main.ts'),oldStore=new URL('../../apps/daemon/src/store.ts',import.meta.url).href;
async function freePort(){const s=createServer();await new Promise(r=>s.listen(0,'127.0.0.1',r));const p=s.address().port;await new Promise(r=>s.close(r));return p;}

test('real Node to Rust to Node data migration preserves journal, output, settings and task inboxes',{timeout:90000},async()=>{
 const root=await realpath(await mkdtemp(join(tmpdir(),'neura-migration-'))),data=join(root,'data'),folder=join(root,'folder'),home=join(root,'home'),port=await freePort(),url=`http://127.0.0.1:${port}`;
 await mkdir(folder);await mkdir(home);const database=join(data,'developer.sqlite');
 const env={...process.env,HOME:home,XDG_CONFIG_HOME:join(home,'.config'),CLAUDE_CONFIG_DIR:join(home,'.claude'),CODEX_HOME:join(home,'.codex'),NEURA_DEV_DATA_DIR:data,NEURA_DEV_PORT:String(port),SHELL:'/bin/sh',PATH:'/usr/bin:/bin:/usr/sbin:/sbin'};
 let child,exit,token,failed=false;const evidence={fixture:root,sequence:[],checks:[]};
 const request=async(path,body)=>{const r=await fetch(url+path,{method:body===undefined?'GET':'POST',headers:{authorization:`Bearer ${token}`,'content-type':'application/json'},body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(15000)});return {status:r.status,value:await r.json()};};
 const command=(command,operationId=randomUUID())=>request('/v1/commands',{operationId,command});
 const ok=async promise=>{const r=await promise;assert.equal(r.status,200,JSON.stringify(r.value));return r.value;};
 async function start(kind){assert.ok(!child||child.exitCode!==null||child.signalCode!==null,'old process must exit before replacement');let stderr='';child=spawn(kind==='node'?process.execPath:binary,kind==='node'?['--import',loader,legacy]:[],{cwd:repository,env,stdio:['ignore','pipe','pipe'],detached:true});child.stdout.resume();child.stderr.on('data',b=>stderr=(stderr+b).slice(-4000));let spawnError;child.on('error',e=>spawnError=e);exit=new Promise(r=>child.once('exit',(code,signal)=>r({code,signal})));for(let n=0;n<250;n++){if(spawnError)throw spawnError;if(child.exitCode!==null)throw Error(`Fixture daemon exited (${kind}) ${stderr}`);try{token=(await readFile(join(data,'daemon-token'),'utf8')).trim();const r=await request('/v1/state');if(r.status===200){assert.equal(r.value.runtime==='rust',kind==='rust');evidence.sequence.push(kind);return r.value;}}catch{}await sleep(40);}throw Error(`Fixture startup timed out (${kind})`);}
 async function stop(){if(!child||child.exitCode!==null||child.signalCode!==null)return;child.kill('SIGTERM');let timer;const result=await Promise.race([exit,new Promise(r=>timer=setTimeout(()=>r(null),12000))]);clearTimeout(timer);if(!result){process.kill(-child.pid,'SIGKILL');await exit;throw Error('Fixture did not stop cleanly');}assert.equal(result.code,0);}
 async function until(check){for(let n=0;n<200;n++){if(await check())return;await sleep(20);}throw Error('Fixture state deadline');}
 function offline(){assert.ok(child.exitCode!==null||child.signalCode!==null);return new DatabaseSync(database,{readOnly:true});}
 async function emit(workspaceId,text){const t=await ok(command({type:'terminal.open',workspaceId,provider:'shell'}));await ok(command({type:'terminal.input',terminalId:t.id,clientId:randomUUID(),data:`printf '${text}\\n'; exit\n`}));await until(async()=>{const s=await ok(request('/v1/state'));return s.terminals.find(v=>v.id===t.id).status==='exited';});const output=await ok(request(`/v1/terminals/${t.id}/output?after=0`));assert.match(output.data,new RegExp(text));return {id:t.id,output};}
 try{
  await start('node');const firstToken=token;const addId=randomUUID(),add={type:'project.add',path:folder};const project=await ok(command(add,addId));
  const state=await ok(request('/v1/state')),workspace=state.workspaces.find(w=>w.projectId===project.id);
  await ok(command({type:'project.set-default-providers',projectId:project.id,defaultConversationProvider:'claude',defaultDelegationProvider:'codex'}));
  await ok(command({type:'project.set-worktree-startup',projectId:project.id,providers:['shell','claude']}));
  const before=await emit(workspace.id,'legacy-日本語-😀');const failedId=randomUUID(),bad={type:'file.save',workspaceId:randomUUID(),path:'missing.txt',content:'x',expectedHash:'0'.repeat(64)};const failedResult=await command(bad,failedId);assert.equal(failedResult.status,404);await stop();
  const terminalId=randomUUID(),agentIds=[randomUUID(),randomUUID()],reportIds=[randomUUID(),randomUUID()],pendingId=randomUUID(),unknownId=randomUUID(),unknownCommand={type:'project.create',name:'uncertain'};
  const notification={id:randomUUID(),createdAt:new Date().toISOString(),terminalId,kind:'completed',provider:'claude',workspaceId:workspace.id,workspaceName:'移行通知',sessionName:'日本語',at:new Date().toISOString()};
  const agentRecords=agentIds.map((id,i)=>({id,terminalId:i===0?terminalId:randomUUID(),workspaceId:workspace.id,name:`migration-${i}`,provider:'claude',status:'working',turnId:randomUUID(),lastTurnId:randomUUID(),lastTurnStatus:'completed',summary:'既存summary 日本語',parentTaskId:i===1?agentIds[0]:undefined,updatedAt:new Date().toISOString(),pending:[{id:pendingId,text:'未実行の依頼 😀'}],requests:[{id:1,method:'fixture',params:{}}],reports:[{id:reportIds[i],kind:'manual',text:'未受領の報告 日本語',createdAt:new Date().toISOString()}],watching:[]}));
  // Seed both a pre-lifecycle record and a record written by the new native
  // schema through the legacy Store. Unknown JSON fields must survive rollback.
  const historyAt='2026-10-30T00:00:00.000Z';
  agentRecords[1].pending[0]={...agentRecords[1].pending[0],state:'queued',history:[{state:'queued',at:historyAt,actorTaskId:agentIds[0]}]};
  agentRecords[1].revision=7;agentRecords[1].instructionHistoryPruned=9;
  agentRecords[1].instructions=['consumed','cancelled','superseded','delivered','unknown','delivering'].map(state=>({id:randomUUID(),text:`保持する ${state} 日本語 😀`,state,history:[{state,at:historyAt,actorTaskId:agentIds[1]}]}));
  const lifecycle=a=>({pending:a.pending,instructions:a.instructions,revision:a.revision,instructionHistoryPruned:a.instructionHistoryPruned});
  const seed=`import {Store,hash} from ${JSON.stringify(oldStore)};import {Command} from ${JSON.stringify(new URL('../../apps/daemon/src/contracts.ts',import.meta.url).href)};const store=new Store(${JSON.stringify(database)});const terminal=${JSON.stringify({id:terminalId,workspaceId:workspace.id,provider:'claude',sessionId:agentIds[0],status:'running',cols:123,rows:45,createdAt:new Date().toISOString()})};store.put('terminals',terminal,${JSON.stringify(notification)});store.resize(terminal.id,123,45);store.append(terminal.id,'legacy seeded 日本語 😀\\n');for(const a of ${JSON.stringify(agentRecords)})store.put('agents',a);const c=Command.parse(${JSON.stringify(unknownCommand)});store.db.prepare("INSERT INTO operations(id,hash,status,result) VALUES(?,?,'pending',NULL)").run(${JSON.stringify(unknownId)},hash(JSON.stringify(c)));store.close();`;
  await exec(process.execPath,['--import',loader,'--input-type=module','-e',seed],{cwd:repository,env});
  const db=offline();const oldOperations=db.prepare('SELECT * FROM operations ORDER BY id').all();db.close();
  const native=await start('rust');assert.equal(token,firstToken);assert.equal(native.terminals.find(t=>t.id===terminalId).status,'interrupted');const currentProject=native.projects.find(p=>p.id===project.id);assert.equal(currentProject.defaultConversationProvider,'claude');assert.deepEqual(currentProject.worktreeStartup,['shell','claude']);
  assert.deepEqual(await ok(command(add,addId)),project);assert.equal((await command({...add,path:home},addId)).status,409);assert.deepEqual(await command(bad,failedId),failedResult);assert.equal((await command(unknownCommand,unknownId)).value.error,'operation_unknown');
  const migrated=await ok(request(`/v1/terminals/${before.id}/output?after=0`));assert.equal(migrated.data,before.output.data);assert.deepEqual(migrated.chunks,before.output.chunks);assert.equal(migrated.cursor,before.output.cursor);
  const notices=await ok(request('/v1/notifications?after=0'));assert.ok(notices.events.some(n=>n.terminalId===terminalId&&n.workspaceName==='移行通知'));
  const agents=await ok(request('/v1/agents'));assert.equal(agents.currentSessionIds[terminalId],agentIds[0]);for(const id of agentIds){const a=agents.agents.find(a=>a.id===id);assert.equal(a.status,'interrupted');assert.equal(a.turnId,undefined);const old=agentRecords.find(v=>v.id===id);
   assert.equal(a.pending.length,1);assert.equal(a.pending[0].id,pendingId);assert.equal(a.pending[0].text,old.pending[0].text);assert.equal(a.pending[0].state,'queued');
   if(old.pending[0].history)assert.deepEqual(a.pending,old.pending);
   else {assert.equal(a.pending[0].history.length,1);assert.equal(a.pending[0].history[0].state,'queued');assert.equal(a.pending[0].history[0].actorTaskId,null);assert.ok(Number.isFinite(Date.parse(a.pending[0].history[0].at)));}
   assert.equal(a.instructionHistoryPruned,old.instructionHistoryPruned??0);assert.ok(a.revision>(old.revision??0));
   if(!old.instructions)assert.deepEqual(a.instructions,[]);
   else {assert.equal(a.instructions.length,old.instructions.length);for(const expected of old.instructions){const migrated=a.instructions.find(m=>m.id===expected.id);assert.equal(migrated.text,expected.text);if(expected.state==='delivering'){assert.equal(migrated.state,'unknown');assert.deepEqual(migrated.history.slice(0,-1),expected.history);assert.equal(migrated.history.at(-1).state,'unknown');assert.equal(migrated.history.at(-1).actorTaskId,null);assert.ok(Number.isFinite(Date.parse(migrated.history.at(-1).at)));}else assert.deepEqual(migrated,expected);}}
   assert.equal(a.reports[0].text,'未受領の報告 日本語');assert.equal(a.lastTurnId,agentRecords.find(v=>v.id===id).lastTurnId);assert.equal(a.summary,'既存summary 日本語');}
  await ok(command({type:'agent.ack',agentId:agentIds[0],reportIds:[reportIds[0]]}));
  const durableLifecycle=new Map((await ok(request('/v1/agents'))).agents.map(a=>[a.id,lifecycle(a)]));
  const nativeOp=randomUUID(),nativeCommand={type:'project.create',name:'native 日本語'};const nativeProject=await ok(command(nativeCommand,nativeOp));const after=await emit(workspace.id,'native-移行-😀');await stop();
  const nativeDb=offline();for(const a of agentIds){const row=JSON.parse(nativeDb.prepare('SELECT data FROM agents WHERE id=?').get(a).data);assert.equal(row.status,'interrupted','native recovery must be durable, not only cached');assert.equal(row.turnId,undefined);assert.deepEqual(row.requests,[]);assert.deepEqual(lifecycle(row),durableLifecycle.get(a),'native persisted lifecycle must match its API snapshot');}for(const row of oldOperations)assert.deepEqual(nativeDb.prepare('SELECT * FROM operations WHERE id=?').get(row.id),row);nativeDb.close();
  const rollback=await start('node');assert.equal(token,firstToken);assert.ok(rollback.projects.some(p=>p.id===nativeProject.id));assert.deepEqual(await ok(command(nativeCommand,nativeOp)),nativeProject);assert.deepEqual((await ok(request(`/v1/terminals/${after.id}/output?after=0`))).chunks,after.output.chunks);assert.deepEqual(await ok(command(add,addId)),project);assert.deepEqual(await command(bad,failedId),failedResult);assert.equal((await command(unknownCommand,unknownId)).value.error,'operation_unknown');
  const restored=await ok(request('/v1/agents'));assert.equal(restored.agents.find(a=>a.id===agentIds[0]).reports.length,0);assert.equal(restored.agents.find(a=>a.id===agentIds[0]).pending.length,1);assert.equal(restored.agents.find(a=>a.id===agentIds[1]).reports[0].id,reportIds[1]);assert.deepEqual(await ok(request('/v1/notifications?after=0')),notices);
  for(const a of restored.agents)assert.deepEqual(lifecycle(a),durableLifecycle.get(a.id),'Node rollback must preserve full pending state/history, archived states and retention counters');
  // Exercise a legacy mutation, not just a read, while retaining native fields.
  await ok(command({type:'agent.ack',agentId:agentIds[1],reportIds:[reportIds[1]]}));
  const mutated=await ok(request('/v1/agents'));for(const a of mutated.agents)assert.deepEqual(lifecycle(a),durableLifecycle.get(a.id));
  await stop();const rollbackDb=offline();for(const id of agentIds){const a=JSON.parse(rollbackDb.prepare('SELECT data FROM agents WHERE id=?').get(id).data);assert.deepEqual(lifecycle(a),durableLifecycle.get(id),'Node rollback mutation must durably retain lifecycle fields');}rollbackDb.close();
  evidence.checks=['Unicode PTY+cursor/chunks','project/settings/workspace','notifications','agent pending/reports/exact ACK','legacy and native pending state/history','terminal and unconsumed/unknown instruction history','Node rollback mutation retains native lifecycle fields','durable running recovery','operation hash/result/conflict/pending_unknown','native writes read by legacy','token retained','strict stop-before-start'];evidence.tokenSha256=createHash('sha256').update(firstToken).digest('hex');evidence.ok=true;
 }catch(e){failed=true;evidence.ok=false;evidence.failure=String(e);throw e;}finally{try{await stop();}finally{await writeFile(join(root,'evidence.json'),JSON.stringify(evidence,null,2));console.error(`Migration evidence: ${join(root,'evidence.json')}`);if(!failed&&process.env.NEURA_KEEP_FIXTURES!=='1')await rm(root,{recursive:true,force:true});}}
});
