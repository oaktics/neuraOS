import {test} from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {mkdtemp,rm,mkdir,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {setup,input,user,runner} from './helpers.ts';
import {LocalStore} from '../packages/sync/src/local-store.ts';
import {Hub} from '../apps/runner/src/hub.ts';
import {Engine} from '../apps/runner/src/engine.ts';
import {FixtureAdapter} from '../packages/adapters/fixture.ts';

test('project provider is inherited and a conversation cannot cross project scope',()=>{
 const x=setup(),projectId=randomUUID();x.apply({type:'project.save',id:projectId,name:'research',description:'',instructions:'',classification:'standard',provider:'claude',maxWorkers:2});
 const taskId=randomUUID();x.apply({type:'task.create',id:taskId,input:input({projectId,provider:'codex'})});assert.equal(x.state.tasks.find(t=>t.id===taskId)!.provider,'claude');
 const conversationId=randomUUID();x.apply({type:'chat.send',id:randomUUID(),conversationId,projectId,provider:'codex',content:'相談です'});assert.equal(x.state.conversations![0].provider,'claude');
 assert.throws(()=>x.apply({type:'chat.send',id:randomUUID(),conversationId,projectId:null,provider:'codex',content:'別の範囲'}),/conversation_scope/);
 assert.throws(()=>x.apply({type:'chat.send',id:randomUUID(),conversationId:randomUUID(),projectId:null,provider:'codex',content:'外部資料からの指示'},runner),/user_required/);
});
test('vice president cannot delegate restricted project work or dispatch an invented proposal',()=>{
 const x=setup();const projectId=randomUUID();x.apply({type:'project.save',id:projectId,name:'private',description:'',instructions:'',classification:'restricted',provider:'codex'});
 const conversationId=randomUUID(),id=randomUUID();x.apply({type:'chat.send',id,conversationId,projectId:null,provider:'fixture',content:'相談'});x.apply({type:'run.claim',taskId:id,runnerId:runner.deviceId!},runner);const run=x.state.tasks.find(t=>t.id===id)!.runs[0];
 assert.throws(()=>x.apply({type:'chat.result',taskId:id,runId:run.id,fencingToken:run.fencingToken,reply:{reply:'提案',proposals:[{projectId,title:'秘密',objective:'秘密',deliverable:'秘密'}]}},runner),/project_scope/);
 assert.throws(()=>x.apply({type:'chat.delegate',conversationId,messageId:randomUUID(),proposalIndex:0,id:randomUUID()}),/proposal_missing/);
});
test('president consultation -> director -> parallel employees -> collection -> human acceptance is durable',async()=>{
 const dir=await mkdtemp(join(tmpdir(),'neura-team-')),workspaceId=randomUUID(),deviceId=randomUUID(),projectId=randomUUID(),conversationId=randomUUID();const store=new LocalStore(join(dir,'db'),workspaceId),hub=new Hub(store,{dataDir:dir,workspaceId,deviceId,port:0,cloudUrl:null,githubClientId:null,allowFixtures:true}),engine=new Engine(hub);
 const fixture=new FixtureAdapter();let activeEmployees=0,maxEmployees=0;const contexts:string[]=[];
 engine.adapters.fixture={probeCapabilities:()=>fixture.probeCapabilities(),execute:async c=>{if(c.task.projectId&&c.task.work?.phase!=='reviewing')contexts.push(JSON.stringify(c.workspace));if(c.task.work?.phase==='reviewing')assert.equal(c.workspace,undefined);if(c.task.work?.role==='employee'){activeEmployees++;maxEmployees=Math.max(maxEmployees,activeEmployees);try{await new Promise(r=>setTimeout(r,100));return await fixture.execute(c);}finally{activeEmployees--;}}return fixture.execute(c);}};
 const until=async(predicate:()=>boolean)=>{const end=Date.now()+8000;while(!predicate()){assert.ok(Date.now()<end,'team did not finish');await engine.tick();await new Promise(r=>setTimeout(r,30));}};
 try{
  await hub.execute({type:'device.register',id:deviceId,name:'team test',publicKey:'test'});await hub.execute({type:'project.save',id:projectId,name:'比較',description:'',instructions:'',classification:'standard',provider:'fixture',maxWorkers:2});
  await mkdir(join(dir,'project'));await writeFile(join(dir,'project','README.md'),'bound-read-only-proof');await engine.workspace.bind(projectId,join(dir,'project'));
  await hub.execute({type:'chat.send',id:randomUUID(),conversationId,projectId:null,provider:'fixture',content:'比較資料を作りたい'});await until(()=>!!hub.read().conversations?.[0].messages.some(m=>m.role==='assistant'));
  const message=hub.read().conversations![0].messages.find(m=>m.role==='assistant')!,directorId=randomUUID();await hub.execute({type:'chat.delegate',conversationId,messageId:message.id,proposalIndex:0,id:directorId});
  await assert.rejects(()=>hub.execute({type:'chat.delegate',conversationId,messageId:message.id,proposalIndex:0,id:randomUUID()}),/already_delegated/);
  await until(()=>hub.read().tasks.find(t=>t.id===directorId)?.status==='waiting_input');
  const children=hub.read().tasks.filter(t=>t.work?.parentId===directorId),director=hub.read().tasks.find(t=>t.id===directorId)!;assert.equal(children.length,2);assert.equal(maxEmployees,2);assert.ok(children.every(t=>t.provider==='fixture'&&t.status==='succeeded'));assert.ok(contexts.length>=3);assert.ok(contexts.every(c=>c.includes('bound-read-only-proof')));assert.equal(engine.workspace.worktrees().length,0);assert.equal(director.work?.phase,'finished');assert.equal(director.runs[0].calls,2);assert.ok(director.artifacts.some(a=>a.name==='result.md'));
  await hub.execute({type:'verification.accept',taskId:directorId,expectedVersion:director.version,criterionId:director.criteria.find(c=>c.kind==='human')!.id,passed:true,evidence:'社長が集約結果を確認'});await until(()=>hub.read().tasks.find(t=>t.id===directorId)?.status==='succeeded');
  await engine.shutdown();store.close();const reopened=new LocalStore(join(dir,'db'),workspaceId);assert.equal(reopened.read().conversations![0].messages.length,2);assert.equal(reopened.read().tasks.filter(t=>t.work?.parentId===directorId).length,2);reopened.close();
 }finally{await engine.shutdown();try{store.close();}catch{}await rm(dir,{recursive:true,force:true});}
});
test('parent pause/cancel controls employees, stale planners cannot create a team, plan alone cannot be accepted',()=>{
 const x=setup(),projectId=randomUUID(),conversationId=randomUUID(),chatId=randomUUID(),directorId=randomUUID();
 x.apply({type:'project.save',id:projectId,name:'team',description:'',instructions:'',classification:'standard',provider:'fixture',maxWorkers:2});x.apply({type:'chat.send',id:chatId,conversationId,projectId:null,provider:'fixture',content:'整理してください'});x.apply({type:'run.claim',taskId:chatId,runnerId:runner.deviceId!},runner);
 const chat=x.state.tasks.find(t=>t.id===chatId)!.runs[0];x.apply({type:'chat.result',taskId:chatId,runId:chat.id,fencingToken:chat.fencingToken,reply:{reply:'提案',proposals:[{projectId,title:'整理',objective:'資料を整理',deliverable:'メモ'}]}},runner);const message=x.state.conversations![0].messages.find(m=>m.role==='assistant')!;
 x.apply({type:'chat.delegate',conversationId,messageId:message.id,proposalIndex:0,id:directorId});x.apply({type:'run.claim',taskId:directorId,runnerId:runner.deviceId!},runner);
 const director=()=>x.state.tasks.find(t=>t.id===directorId)!,run=director().runs[0],lease={taskId:directorId,runId:run.id,fencingToken:run.fencingToken},plan={summary:'二つの視点',assignments:[{title:'A',objective:'Aを整理',output:'A.md'},{title:'B',objective:'Bを整理',output:'B.md'}]};
 x.apply({type:'artifact.add',...lease,id:randomUUID(),name:'team-plan.json',mediaType:'application/json',content:JSON.stringify(plan)},runner);
 assert.throws(()=>x.apply({type:'verification.accept',taskId:directorId,expectedVersion:director().version,criterionId:director().criteria.find(c=>c.kind==='human')!.id,passed:true,evidence:'計画だけの受け入れ'}),/team_not_ready_for_acceptance/);
 assert.throws(()=>x.apply({type:'team.plan',...lease,fencingToken:0,plan},runner),/stale_fence/);x.apply({type:'team.plan',...lease,plan},runner);
 const children=()=>x.state.tasks.filter(t=>t.work?.parentId===directorId);assert.equal(children().length,2);
 x.apply({type:'task.control',taskId:directorId,expectedVersion:director().version,action:'pause'});assert.ok(children().every(t=>t.status==='paused'));
 x.apply({type:'task.control',taskId:directorId,expectedVersion:director().version,action:'resume'});assert.ok(children().every(t=>t.status==='queued'));assert.equal(director().status,'blocked');
 x.apply({type:'task.control',taskId:directorId,expectedVersion:director().version,action:'cancel'});assert.ok(children().every(t=>t.status==='canceled'));
 assert.throws(()=>x.apply({type:'task.queue',taskId:directorId,expectedVersion:director().version}),/team_run_not_repeatable/);
});
