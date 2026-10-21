import Fastify from 'fastify';
import { verify } from 'node:crypto';
import { z } from 'zod';
import { Envelope, Id } from '../../../packages/contracts/src/index.ts';
import type { Actor, State } from '../../../packages/contracts/src/index.ts';
import { contentHash, DomainError, ensure, canonical } from '../../../packages/policy/src/index.ts';
import type { PostgresStore } from './store.ts';
import type { BlobStore } from '../../../packages/sync/src/storage.ts';
import { randomUUID } from 'node:crypto';

export function cloudServer(store:PostgresStore,blobs:BlobStore,options:{allowedGitHubIds:string[];authenticate?:(token:string)=>Promise<string>}){
  const app=Fastify({bodyLimit:12*1024*1024,logger:false});
  const authenticate=options.authenticate??(async(token:string)=>{
    const r=await fetch('https://api.github.com/user',{headers:{authorization:`Bearer ${token}`,accept:'application/vnd.github+json','X-GitHub-Api-Version':'2022-11-28','User-Agent':'neuraOS/0.1.0'},signal:AbortSignal.timeout(10000),redirect:'error'});
    ensure(r.ok,'unauthenticated');const account=await r.json() as {id:number};ensure(options.allowedGitHubIds.includes(String(account.id)),'account_not_allowed');return `github:${account.id}`;
  });
  app.setErrorHandler((error,_req,res)=>{const e=error as Error;const code=e instanceof DomainError?e.code:e instanceof z.ZodError?'invalid_request':'request_failed';res.code(e instanceof DomainError?e.status:e instanceof z.ZodError?400:500).send({error:code});});
  app.get('/health',async()=>({status:'ok',version:'0.1.0'}));
  app.addHook('preHandler',async(req,reply)=>{
    if(req.url==='/health')return;
    const token=req.headers.authorization?.replace(/^Bearer /,'');if(!token){reply.code(401).send({error:'unauthenticated'});return;}
    try{(req as unknown as {userId:string}).userId=await authenticate(token);}catch{reply.code(401).send({error:'unauthenticated'});}
  });
  const identity=(req:unknown)=>(req as {userId:string}).userId;
  async function actorFor(req:{headers:Record<string,unknown>;method:string;url:string;body?:unknown},state:State,userId:string):Promise<Actor>{
    const deviceId=req.headers['x-neura-device'];if(!deviceId)return {id:userId,role:'user'};
    const device=state.devices.find(d=>d.id===deviceId&&d.status==='active');ensure(device,'device_revoked');
    const timestamp=String(req.headers['x-neura-time']??'');ensure(Math.abs(Date.now()-Number(timestamp))<60000,'signature_expired');
    const signature=String(req.headers['x-neura-signature']??'');
    const data=canonical({method:req.method,url:req.url,time:timestamp,body:req.body??null});
    ensure(verify(null,Buffer.from(data),device.publicKey,Buffer.from(signature,'base64')),'device_signature_invalid');return {id:device.id,role:'runner',deviceId:device.id};
  }
  app.post('/workspaces',async req=>{const {id}=z.object({id:Id}).parse(req.body);return store.create(id,identity(req));});
  app.get('/workspaces/:id',async req=>{const {id}=z.object({id:Id}).parse(req.params);const state=await store.read(id,identity(req));await actorFor(req,state,identity(req));return state;});
  app.post('/workspaces/:id/commands',async req=>{
    const {id}=z.object({id:Id}).parse(req.params);const e=Envelope.parse(req.body);
    const state=await store.read(id,identity(req));const actor=await actorFor(req,state,identity(req));return store.apply(id,identity(req),e,actor);
  });
  app.post('/workspaces/:id/artifacts/:artifactId/store',async req=>{
    const {id,artifactId}=z.object({id:Id,artifactId:Id}).parse(req.params);const user=identity(req);const state=await store.read(id,user);const actor=await actorFor(req,state,user);ensure(actor.role==='runner','runner_required');
    const task=state.tasks.find(t=>t.artifacts.some(a=>a.id===artifactId));ensure(task,'artifact_missing');const a=task.artifacts.find(a=>a.id===artifactId)!;const run=task.runs.find(r=>r.id===a.runId)!;
    const key=`${id}/${task.id}/${a.id}/${a.hash}`;await blobs.put(key,a.content);ensure(contentHash(await blobs.get(key))===a.hash,'storage_readback_mismatch');
    return store.apply(id,user,{operationId:randomUUID(),command:{type:'artifact.stored',taskId:task.id,runId:run.id,fencingToken:run.fencingToken,artifactId:a.id,key,hash:a.hash}},actor);
  });
  app.get('/workspaces/:id/artifacts/:artifactId',async req=>{const {id,artifactId}=z.object({id:Id,artifactId:Id}).parse(req.params);const s=await store.read(id,identity(req));await actorFor(req,s,identity(req));const a=s.tasks.flatMap(t=>t.artifacts).find(a=>a.id===artifactId);ensure(a?.cloudKey,'artifact_not_stored');const content=await blobs.get(a.cloudKey);ensure(contentHash(content)===a.hash,'artifact_corrupt');return {content,hash:a.hash};});
  return app;
}
