import {test} from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp,mkdir,writeFile,readFile,realpath,rm} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import {tmpdir} from 'node:os';
import {fileURLToPath} from 'node:url';
import {createServer} from 'node:net';
import {createInterface} from 'node:readline';
import {randomUUID} from 'node:crypto';
import {setTimeout as delay} from 'node:timers/promises';
const binary=process.env.NEURA_NATIVE_DAEMON;
const quote=s=>"'"+s.replaceAll("'","'\\''")+"'";
async function until(check){const end=Date.now()+15000;do{if(await check())return;await delay(25);}while(Date.now()<end);assert.fail('fixture deadline');}
test('native MCP task controls: diagnostics, durable exact instruction lifecycle and server-side list', {skip:!binary,timeout:90000},async t=>{
 const root=await realpath(await mkdtemp(join(tmpdir(),'neura-task-control-'))),home=join(root,'home'),data=join(root,'data'),folder=join(root,'folder'),bin=join(home,'.local/bin');
 await mkdir(bin,{recursive:true});await mkdir(folder);
 const fixture=fileURLToPath(new URL('./fixtures/provider-daemon-cli.mjs',import.meta.url));
 await writeFile(join(bin,'codex'),`#!/bin/sh\nexec ${quote(process.execPath)} ${quote(fixture)} codex "$@"\n`,{mode:0o700});
 const listener=createServer();await new Promise(r=>listener.listen(0,'127.0.0.1',r));const port=listener.address().port;await new Promise(r=>listener.close(r));
 const base=`http://127.0.0.1:${port}`,env={HOME:home,PATH:bin+':/usr/bin:/bin',LANG:'en_US.UTF-8',TMPDIR:root,NEURA_DEV_DATA_DIR:data,NEURA_DEV_PORT:String(port),NEURA_CODEX_PATH:join(bin,'codex')};
 let daemon,daemonEnd,mcp,token,logs='';
 async function start(){daemon=spawn(resolve(binary),[],{cwd:root,env,stdio:['ignore','pipe','pipe']});daemonEnd=new Promise(r=>daemon.once('exit',code=>r(code)));for(const s of [daemon.stdout,daemon.stderr])s.on('data',b=>logs=(logs+b).slice(-8192));await until(async()=>{assert.equal(daemon.exitCode,null,logs);try{token=(await readFile(join(data,'daemon-token'),'utf8')).trim();return (await request('/v1/state')).runtime==='rust';}catch{return false;}});}
 async function stop(){
  daemon.kill('SIGTERM');let timer;
  const result=await Promise.race([daemonEnd,new Promise(r=>timer=setTimeout(()=>r('timeout'),15000))]);clearTimeout(timer);
  if(result==='timeout'){daemon.kill('SIGKILL');await daemonEnd;}
  assert.equal(result,0,logs);
 }
 async function request(path,body,status=200){const r=await fetch(base+path,{method:body===undefined?'GET':'POST',headers:{authorization:`Bearer ${token}`,'content-type':'application/json'},body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(15000)});const value=await r.json();assert.equal(r.status,status,JSON.stringify(value));return value;}
 const command=(c,operationId=randomUUID())=>request('/v1/commands',{operationId,command:c});
 try{
  await start();
  const project=await command({type:'project.add',path:folder});const workspace=(await request('/v1/state')).workspaces.find(w=>w.projectId===project.id);
  const terminal=await command({type:'terminal.open',workspaceId:workspace.id,provider:'codex'});
  let task;await until(async()=>{task=(await request('/v1/agents')).agents.find(a=>a.terminalId===terminal.id);return task;});
  await until(async()=> (await request(`/v1/terminals/${terminal.id}/output?after=0&chunksOnly=true`)).chunks.some(c=>c.data.includes('FIXTURE_READY')));
  await command({type:'terminal.input',terminalId:terminal.id,clientId:randomUUID(),data:'work\n'});
  await until(async()=> (await request('/v1/agents')).agents.find(a=>a.id===task.id).status==='working');
  mcp=spawn(resolve(binary),['mcp'],{env:{...env,NEURA_SUPERVISION_URL:base,NEURA_SUPERVISION_TOKEN_FILE:join(data,'daemon-token'),NEURA_SUPERVISION_TERMINAL:terminal.id,NEURA_SUPERVISION_WORKSPACE:workspace.id},stdio:['pipe','pipe','pipe']});
  const mcpEnd=new Promise(r=>mcp.once('exit',r));let sequence=0;const waiters=new Map();
  createInterface({input:mcp.stdout}).on('line',line=>{const m=JSON.parse(line);waiters.get(m.id)?.(m);waiters.delete(m.id);});
  const rpc=(method,params={})=>new Promise((resolve,reject)=>{const id=++sequence;const timer=setTimeout(()=>{waiters.delete(id);reject(new Error('MCP timeout'));},15000);waiters.set(id,m=>{clearTimeout(timer);resolve(m);});mcp.stdin.write(JSON.stringify({jsonrpc:'2.0',id,method,params})+'\n');});
  const tool=async(name,args={})=>{const r=(await rpc('tools/call',{name,arguments:args})).result;return {error:r.isError??false,value:JSON.parse(r.content[0].text)};};
  await rpc('initialize');
  const tools=(await rpc('tools/list')).result.tools;
  for(const tool of tools.filter(t=>t.inputSchema.properties.operationId)){assert.match(tool.description,/UUID/);assert.match(tool.inputSchema.properties.operationId.description,/UUID/);}
  assert.ok(tools.some(t=>t.name==='task_instruction'));
  const c={type:'agent.send',agentId:task.id,text:'private-body',mode:'queue'};
  for(const [body,reason] of [[{command:c},'required'],[{operationId:'not-a-uuid-secret',command:c},'expected_uuid']]){
   const error=await request('/v1/commands',body,400);assert.equal(error.field,'operationId');assert.equal(error.reason,reason);assert.ok(!JSON.stringify(error).includes('secret'));assert.ok(!JSON.stringify(error).includes('private-body'));
  }
  const bad=await tool('task_send',{taskId:task.id,text:'secret body'});assert.equal(bad.value.reason,'required');assert.equal(bad.value.field,'operationId');
  assert.equal((await tool('task_send',{operationId:'bad-secret',taskId:task.id,text:'private'})).value.reason,'expected_uuid');
  const badField=await request('/v1/commands',{operationId:randomUUID(),command:{...c,text:42}},400);assert.equal(badField.field,'text');assert.equal(badField.reason,'invalid_value');
  const sendArgs={operationId:randomUUID(),taskId:task.id,text:'obsolete design'};
  const old=(await tool('task_send',sendArgs)).value;assert.deepEqual((await tool('task_send',sendArgs)).value,old);
  const keep=(await tool('task_send',{operationId:randomUUID(),taskId:task.id,text:'keep this work'})).value;
  const before=(await tool('task_read',{taskId:task.id})).value.agent;
  assert.deepEqual((await tool('task_read',{taskId:task.id})).value.agent,before);
  const replacement={operationId:randomUUID(),taskId:task.id,instructionId:old.messageId,expectedRevision:before.revision,expectedTurnId:before.turnId,expectedState:'queued',action:'supersede',text:'current design'};
  const changed=await tool('task_instruction',replacement);assert.equal(changed.error,false);
  assert.deepEqual(await tool('task_instruction',replacement),changed);
  const conflict=await tool('task_instruction',{...replacement,operationId:randomUUID()});assert.equal(conflict.error,true);assert.equal(conflict.value.error,'instruction_revision_changed');
  const after=(await tool('task_read',{taskId:task.id})).value.agent;
  assert.deepEqual(after.pending.map(m=>m.text),['current design','keep this work']);assert.equal(after.instructions.find(i=>i.id===old.messageId).state,'superseded');
  // Evict the original terminal record while preserving both active items;
  // retry must still replay the durable operation result after that eviction.
  for(let i=0;i<130;i++){
   const queued=await command({type:'agent.send',agentId:task.id,text:`retention ${i}`});
   const current=(await request('/v1/agents')).agents.find(a=>a.id===task.id);
   await command({type:'agent.instruction',agentId:task.id,sourceTerminalId:terminal.id,instructionId:queued.messageId,expectedRevision:current.revision,expectedTurnId:current.turnId,expectedState:'queued',action:'cancel'});
  }
  const bounded=(await tool('task_read',{taskId:task.id})).value.agent;
  assert.equal(bounded.instructions.length,128);assert.equal(bounded.instructionHistoryPruned,3);
  assert.equal(bounded.instructions.some(i=>i.id===old.messageId),false);
  assert.deepEqual(bounded.pending.map(m=>m.text),['current design','keep this work']);
  assert.deepEqual(await tool('task_instruction',replacement),changed);
  const full=(await tool('task_list')).value;assert.equal(full.agents.length,1);
  const lite=(await tool('task_list',{taskIds:[task.id],workspaceId:workspace.id,status:'working',summaryOnly:true,limit:10})).value;
  assert.equal(lite.agents.length,1);assert.equal(lite.agents[0].pendingCount,2);assert.equal(lite.agents[0].pending,undefined);
  for(const filter of [{workspaceId:randomUUID()},{workspaceId:workspace.id,status:'idle'}])assert.deepEqual((await tool('task_list',{...filter,taskIds:[task.id],summaryOnly:true})).value.agents,[]);
  const delta=(await tool('task_list',{taskIds:[task.id],workspaceId:workspace.id,status:'working',summaryOnly:true,sinceRevision:lite.revision,sinceEpoch:lite.epoch})).value;assert.equal(delta.unchanged,true);assert.deepEqual(delta.agents,[]);
  mcp.stdin.end();assert.equal(await mcpEnd,0);mcp=null;
  await stop();await start();
  const recovered=(await request('/v1/agents')).agents.find(a=>a.id===task.id);
  assert.deepEqual(recovered.pending.map(m=>m.id),[changed.value.replacementId,keep.messageId]);
  assert.equal(recovered.instructions.some(i=>i.id===old.messageId),false);assert.equal(recovered.instructionHistoryPruned,3);
  const {operationId,taskId,...args}=replacement;
  assert.deepEqual(await command({...args,type:'agent.instruction',agentId:taskId,sourceTerminalId:terminal.id},operationId),changed.value);
  const expired=await request('/v1/agents?options='+encodeURIComponent(JSON.stringify({sinceRevision:lite.revision,sinceEpoch:lite.epoch})));assert.equal(expired.fullRefreshRequired,true);
  t.diagnostic(`native tools/list UUID descriptions, validation, operation replay, read-only read, list delta, supersede and SQLite restart passed; full bytes=${JSON.stringify(full).length}, summary bytes=${JSON.stringify(lite).length}`);
 }finally{mcp?.kill();if(daemon?.exitCode===null){await stop();}await rm(root,{recursive:true,force:true});}
});
