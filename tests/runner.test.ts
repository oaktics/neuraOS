import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp,rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { LocalStore } from '../packages/sync/src/local-store.ts';
import { Hub } from '../apps/runner/src/hub.ts';
import { Engine } from '../apps/runner/src/engine.ts';
import { runnerServer } from '../apps/runner/src/server.ts';
import { input } from './helpers.ts';
async function waitFor(predicate:()=>boolean){const until=Date.now()+6000;while(!predicate()){assert.ok(Date.now()<until,'timed out');await new Promise(r=>setTimeout(r,20));}}
test('real Runner + SQLite: fixture generation, independent verification, human acceptance, restart',async()=>{
  const dir=await mkdtemp(join(tmpdir(),'neura-runner-'));const workspaceId=randomUUID(),deviceId=randomUUID(),taskId=randomUUID();const store=new LocalStore(join(dir,'db'),workspaceId);
  const hub=new Hub(store,{dataDir:dir,workspaceId,deviceId,port:0,cloudUrl:null,githubClientId:null,allowFixtures:true});const engine=new Engine(hub);const app=runnerServer(hub,engine,'test-bearer');
  try{
    await hub.execute({type:'device.register',id:deviceId,name:'fixture runner',publicKey:'fixture-public'});
    const humanId=randomUUID();const taskInput=input({criteria:[{id:randomUUID(),kind:'artifact',description:'hash verified',value:'',required:true},{id:humanId,kind:'human',description:'accepted',value:'',required:true}]});
    await hub.execute({type:'task.create',id:taskId,input:taskInput});await hub.execute({type:'task.queue',taskId,expectedVersion:hub.read().tasks[0].version});await engine.tick();
    await waitFor(()=>hub.read().tasks[0].status==='waiting_input');let t=hub.read().tasks[0];assert.equal(t.artifacts.length,1);assert.equal(t.verifications[0].environment,'local');assert.equal(t.provider,'fixture');
    const accepted=await app.inject({method:'POST',url:'/api/command',headers:{authorization:'Bearer test-bearer'},payload:{operationId:randomUUID(),command:{type:'verification.accept',taskId,expectedVersion:t.version,criterionId:humanId,passed:true,evidence:'reviewed fixture'}}});assert.equal(accepted.statusCode,200,accepted.body);
    await waitFor(()=>hub.read().tasks[0].status==='succeeded');await engine.shutdown();store.close();const reopened=new LocalStore(join(dir,'db'),workspaceId);assert.equal(reopened.read().tasks[0].status,'succeeded');assert.equal(reopened.read().tasks[0].artifacts.length,1);reopened.close();
  }finally{await engine.shutdown();await app.close();try{store.close();}catch{}await rm(dir,{recursive:true,force:true});}
});
test('Runner authentication, CSRF, schema and actor boundaries reject unsafe requests',async()=>{
  const dir=await mkdtemp(join(tmpdir(),'neura-api-')),workspaceId=randomUUID(),deviceId=randomUUID();const store=new LocalStore(join(dir,'db'),workspaceId);const hub=new Hub(store,{dataDir:dir,workspaceId,deviceId,port:0,cloudUrl:null,githubClientId:null,allowFixtures:false});const engine=new Engine(hub);const app=runnerServer(hub,engine,'test');
  try{
    assert.equal((await app.inject({url:'/api/state'})).statusCode,401);
    assert.equal((await app.inject({url:'/api/state',headers:{authorization:'Bearer wrong'}})).statusCode,401);
    assert.equal((await app.inject({url:'/api/state',headers:{authorization:'Bearer test',origin:'https://attacker.example'}})).statusCode,403);
    assert.equal((await app.inject({method:'POST',url:'/api/command',headers:{authorization:'Bearer test'},payload:{operationId:randomUUID(),command:{type:'shell',command:'arbitrary'}}})).statusCode,400);
    const r=await app.inject({method:'POST',url:'/api/command',headers:{authorization:'Bearer test'},payload:{operationId:randomUUID(),command:{type:'run.claim',taskId:randomUUID(),runnerId:deviceId}}});assert.equal(r.json().error,'runner_required');
  }finally{await engine.shutdown();await app.close();store.close();await rm(dir,{recursive:true,force:true});}
});
