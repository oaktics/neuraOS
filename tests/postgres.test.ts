import { test } from 'node:test';
import assert from 'node:assert/strict';
import pg from 'pg';
import { randomUUID,generateKeyPairSync,sign } from 'node:crypto';
import { mkdtemp,rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { PostgresStore } from '../apps/cloud-api/src/store.ts';
import { cloudServer } from '../apps/cloud-api/src/server.ts';
import { FileBlobStore } from '../packages/sync/src/storage.ts';
import { canonical,contentHash } from '../packages/policy/src/index.ts';
import { input } from './helpers.ts';
test('PostgreSQL + RLS + HTTP + storage: exclusive lease, idempotency, tenant denial, archive readback',{skip:!process.env.NEURA_TEST_DATABASE_URL},async()=>{
  const pool=new pg.Pool({connectionString:process.env.NEURA_TEST_DATABASE_URL});const store=new PostgresStore(pool);const dir=await mkdtemp(join(tmpdir(),'neura-cloud-'));
  const app=cloudServer(store,new FileBlobStore(dir),{allowedGitHubIds:[],authenticate:async token=>{assert.ok(['owner1','owner2'].includes(token));return token;}});
  const workspaceId=randomUUID(),taskId=randomUUID(),deviceId=randomUUID(),key=generateKeyPairSync('ed25519');
  const user={id:'owner1',role:'user' as const},runner={id:deviceId,role:'runner' as const,deviceId};
  const command=async(c:any)=>store.apply(workspaceId,'owner1',{operationId:randomUUID(),command:c},user);
  try{
    await store.create(workspaceId,'owner1');await assert.rejects(()=>store.read(workspaceId,'owner2'),/workspace_not_found/);
    await command({type:'device.register',id:deviceId,name:'test',publicKey:key.publicKey.export({type:'spki',format:'pem'}).toString()});
    let s=await command({type:'task.create',id:taskId,input:input({cloudRequired:true})});s=await command({type:'task.queue',taskId,expectedVersion:s.tasks[0].version});
    const claims=await Promise.allSettled([1,2].map(()=>store.apply(workspaceId,'owner1',{operationId:randomUUID(),command:{type:'run.claim',taskId,runnerId:deviceId}},runner)));assert.equal(claims.filter(r=>r.status==='fulfilled').length,1);
    s=await store.read(workspaceId,'owner1');const run=s.tasks[0].runs[0],lease={taskId,runId:run.id,fencingToken:run.fencingToken},artifactId=randomUUID();
    const e={operationId:randomUUID(),command:{type:'artifact.add' as const,...lease,id:artifactId,name:'result.md',content:'verified',mediaType:'text/markdown' as const}};
    await store.apply(workspaceId,'owner1',e,runner);await store.apply(workspaceId,'owner1',e,runner);assert.equal((await store.read(workspaceId,'owner1')).tasks[0].artifacts.length,1);
    const path=`/workspaces/${workspaceId}/artifacts/${artifactId}/store`,time=String(Date.now()),body={};
    const signature=sign(null,Buffer.from(canonical({method:'POST',url:path,time,body})),key.privateKey).toString('base64');
    const response=await app.inject({method:'POST',url:path,payload:body,headers:{authorization:'Bearer owner1','x-neura-device':deviceId,'x-neura-time':time,'x-neura-signature':signature}});assert.equal(response.statusCode,200,response.body);assert.ok(response.json().tasks[0].artifacts[0].cloudVerifiedAt);
    const get=await app.inject({url:`/workspaces/${workspaceId}/artifacts/${artifactId}`,headers:{authorization:'Bearer owner1'}});assert.equal(get.json().hash,contentHash('verified'));
    const denied=await app.inject({url:`/workspaces/${workspaceId}`,headers:{authorization:'Bearer owner2'}});assert.equal(denied.json().error,'workspace_not_found');
    await command({type:'device.revoke',id:deviceId});const revoked=await app.inject({method:'POST',url:path,payload:body,headers:{authorization:'Bearer owner1','x-neura-device':deviceId,'x-neura-time':time,'x-neura-signature':signature}});assert.equal(revoked.json().error,'device_revoked');
  }finally{await app.close();await pool.end();await rm(dir,{recursive:true,force:true});}
});
