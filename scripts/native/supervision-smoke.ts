/** Opt-in live Codex test. Uses the signed-in account, a temporary daemon/repository, and real model turns. */
import assert from 'node:assert/strict';
import {mkdtemp,mkdir,writeFile,rm} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import {createDaemon} from '../../apps/daemon/src/server.ts';
import {git} from '../../apps/daemon/src/workspace.ts';
import type {AgentRecord} from '../../apps/daemon/src/agents.ts';
if(process.env.NEURA_LIVE_CODEX_TEST!=='1')throw new Error('Set NEURA_LIVE_CODEX_TEST=1 to run real model turns.');
const root=await mkdtemp('/tmp/neura-supervision-smoke-'),repo=root+'/repo';
await mkdir(repo);await git(repo,['init','-b','main']);await git(repo,['config','user.name','Smoke']);await git(repo,['config','user.email','smoke@example.invalid']);await writeFile(repo+'/README.md','temporary smoke repository\n');await git(repo,['add','.']);await git(repo,['commit','-m','initial']);
let daemon=await createDaemon(root+'/data');await daemon.app.listen({host:'127.0.0.1',port:0});
const headers={authorization:`Bearer ${daemon.token}`};
async function command(command:unknown,operationId=randomUUID()){const response=await daemon.app.inject({method:'POST',url:'/v1/commands',headers,payload:{operationId,command}});assert.equal(response.statusCode,200,response.body);return response.json();}
async function finished(id:string,previous?:string){
  const deadline=Date.now()+150000;
  while(Date.now()<deadline){const a=daemon.store.get<AgentRecord>('agents',id)!;if(a.lastTurnId&&a.lastTurnId!==previous){assert.equal(a.lastTurnStatus,'completed',JSON.stringify(a));return a;}await new Promise(r=>setTimeout(r,500));}
  throw new Error('Timed out waiting for live Codex');
}
try{
  const project=await command({type:'project.add',path:repo});
  const mainWorkspace=daemon.store.state().workspaces.find(w=>w.projectId===project.id)!;
  const workerWorkspace=await command({type:'workspace.create',projectId:project.id,baseRef:'HEAD',skipStartup:true});
  const worker=await command({type:'terminal.open',provider:'codex',workspaceId:workerWorkspace.id});
  const main=await command({type:'terminal.open',provider:'codex',workspaceId:mainWorkspace.id});
  assert.ok(worker.agentId);assert.ok(main.agentId);
  console.log('Started worker first, then supervisor, in separate worktrees.');
  await command({type:'agent.send',agentId:main.agentId,text:'Use ONLY the neuraos task_list MCP tool to count existing Codex sessions. Reply with their count and NEURA_SMOKE_OK. Later, if you receive a neuraos_task_event tool report, reply FOLLOWUP_OK and summarize it without using tools. Do not modify files.',mode:'queue'});
  const initial=await finished(main.agentId);assert.match(initial.summary??'',/NEURA_SMOKE_OK/);
  const history=(await daemon.app.inject({url:'/v1/agents/'+main.agentId,headers})).json();
  assert.ok(history.history.data.flatMap((t:any)=>t.items).some((i:any)=>i.type==='mcpToolCall'&&i.server==='neuraos'&&i.tool==='task_list'));
  console.log('Later supervisor discovered earlier worker via a real MCP tool call.');
  await command({type:'agent.watch',agentId:main.agentId,taskIds:[worker.agentId]});
  const operationId=randomUUID(),send={type:'agent.send',agentId:worker.agentId,text:'Reply exactly WORKER_READY. Do not use tools or modify files.',mode:'queue'};
  const once=await command(send,operationId);assert.deepEqual(await command(send,operationId),once);
  assert.match((await finished(worker.agentId)).summary??'',/WORKER_READY/);
  const followup=await finished(main.agentId,initial.lastTurnId);assert.match(followup.summary??'',/FOLLOWUP_OK/);
  const after=(await daemon.app.inject({url:'/v1/agents/'+main.agentId,headers})).json();
  assert.ok(after.history.data.flatMap((t:any)=>t.items).some((i:any)=>i.type==='functionCallOutput'&&i.name==='neuraos_task_event'));
  console.log('Worker completed; idle supervisor resumed from a tool report. Duplicate send was not replayed.');
  assert.equal((await git(repo,['status','--porcelain'])).trim(),'');
  await daemon.app.close();daemon=await createDaemon(root+'/data');await daemon.app.listen({host:'127.0.0.1',port:0});
  const recovered=(await daemon.app.inject({url:'/v1/agents/'+worker.agentId,headers})).json();assert.equal(recovered.agent.status,'interrupted');assert.ok(recovered.history.data.length);
  const resumed=await command({type:'terminal.open',provider:'codex',workspaceId:workerWorkspace.id,resumeId:worker.agentId});assert.equal(resumed.agentId,worker.agentId);
  await command({type:'agent.send',agentId:worker.agentId,text:'Reply exactly RESUMED_OK. Do not use tools.',mode:'queue'});
  const previous=recovered.agent.lastTurnId;assert.match((await finished(worker.agentId,previous)).summary??'',/RESUMED_OK/);
  console.log('Cold daemon restart, offline conversation read and exact-thread resume passed.');
  console.log(JSON.stringify({result:'passed',workerThread:worker.agentId,supervisorThread:main.agentId,supervisorTurn:followup.lastTurnId}));
}finally{await daemon.app.close();await rm(root,{recursive:true,force:true});}
