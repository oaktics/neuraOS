import {registerWorkspace} from './workspace.ts';
import Fastify from 'fastify';
import {registerChatStreams} from './chat-stream.ts';
import { timingSafeEqual, createHash, generateKeyPairSync, randomUUID } from 'node:crypto';
import { z } from 'zod';
import { writeFile, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { Envelope, Id, TaskInput } from '../../../packages/contracts/src/index.ts';
import { DomainError, ensure } from '../../../packages/policy/src/index.ts';
import { readSecret, writeSecret } from '../../../packages/connectors/src/secrets.ts';
import { GitHubConnector } from '../../../packages/connectors/src/github.ts';
import { fetchPublicSource } from '../../../packages/connectors/src/public-source.ts';
import type { Hub } from './hub.ts';
import type { Engine } from './engine.ts';
export function runnerServer(hub:Hub,engine:Engine,token:string){
  const app=Fastify({bodyLimit:4*1024*1024,logger:false});
  const digest=(s:string)=>createHash('sha256').update(s).digest();
  app.addHook('onRequest',async(req,res)=>{
    const auth=req.headers.authorization??'';
    if(!timingSafeEqual(digest(auth),digest(`Bearer ${token}`))){res.code(401).send({error:'unauthenticated'});return;}
    const origin=req.headers.origin;
    if(origin&&!['http://localhost:1420','http://127.0.0.1:1420','tauri://localhost','http://tauri.localhost'].includes(origin))res.code(403).send({error:'origin_denied'});
  });
  app.setErrorHandler((error,_req,res)=>{const e=error as Error;res.code(e instanceof DomainError?e.status:e instanceof z.ZodError?400:500).send({error:e instanceof DomainError?e.code:e instanceof z.ZodError?'invalid_request':'request_failed',message:e instanceof DomainError?e.message:undefined});});
  registerChatStreams(app,hub,engine);registerWorkspace(app,hub,engine);
  let capabilities:Awaited<ReturnType<Engine['capabilities']>>=[];let checked=0;
  app.get('/api/state',async()=>{
    if(Date.now()-checked>30000){capabilities=await engine.capabilities();checked=Date.now();}
    const drafts=hub.store.db.prepare('SELECT payload FROM drafts').all() as {payload:string}[];
    return {state:hub.read(),mode:hub.config.cloudUrl?'cloud':'local',online:hub.online,syncError:hub.lastError,capabilities,pendingSync:hub.store.pending().length,deviceId:hub.config.deviceId,drafts:drafts.map(d=>JSON.parse(d.payload)),config:{cloudUrl:hub.config.cloudUrl,githubClientId:hub.config.githubClientId,workspaceId:hub.config.workspaceId,allowFixtures:hub.config.allowFixtures},runner:{status:'online',platform:process.platform,version:'0.1.0',dataDir:hub.config.dataDir}};
  });
  app.post('/api/command',async req=>{
    const e=Envelope.parse(req.body);const s=await hub.execute(e.command,'user',e.operationId);
    if(e.command.type==='task.control'||e.command.type==='task.revise')void engine.stop(e.command.taskId);
    void engine.tick();return s;
  });
  app.post('/api/drafts',async req=>{const draft=z.object({id:Id,input:TaskInput}).parse(req.body);hub.store.db.prepare('INSERT INTO drafts VALUES(?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload').run(draft.id,JSON.stringify(draft));return {saved:true};});
  app.post('/api/sources/import',async req=>{const {url}=z.object({url:z.string().url().max(2000)}).parse(req.body);return fetchPublicSource(url);});
  app.post('/api/drafts/:id/publish',async req=>{const {id}=z.object({id:Id}).parse(req.params);const row=hub.store.db.prepare('SELECT payload FROM drafts WHERE id=?').get(id) as {payload:string}|undefined;ensure(row,'draft_missing');const draft=JSON.parse(row.payload);const state=await hub.execute({type:'task.create',id,input:TaskInput.parse(draft.input)});hub.store.db.prepare('DELETE FROM drafts WHERE id=?').run(id);return state;});
  app.post('/api/reconcile',async req=>{const c=z.object({taskId:Id,actionId:Id,externalId:z.string().regex(/^\d+$/)}).parse(req.body);const task=hub.read().tasks.find(t=>t.id===c.taskId);const action=task?.actions.find(a=>a.id===c.actionId);ensure(task&&action,'action_missing');const key=await readSecret(`connector-${action.connectorId}`);ensure(key,'connector_auth_missing');const result=await new GitHubConnector(key).verify(action,c.externalId);return hub.execute({type:'action.reconcile',taskId:task.id,expectedVersion:task.version,actionId:action.id,...result},'runner');});
  app.post('/api/secret',async req=>{const {name,value}=z.object({name:z.string().regex(/^(openai-api-key|anthropic-api-key|cloud-github-token|connector-[0-9a-f-]{36})$/),value:z.string().min(1).max(10000)}).parse(req.body);await writeSecret(name,value);checked=0;return {saved:true};});
  app.post('/api/config',async req=>{
    const c=z.object({cloudUrl:z.string().url().startsWith('https://').nullable(),githubClientId:z.string().max(200).nullable(),workspaceId:Id}).parse(req.body);
    ensure(!hub.read().tasks.some(t=>['running','verifying','waiting_input','waiting_approval'].includes(t.status)),'active_runs');
    await writeFile(join(hub.config.dataDir,'cloud-config.json'),JSON.stringify(c,null,2),{mode:0o600});return {saved:true,restartRequired:true};
  });
  let login:{code:string;expiresAt:number;nextPoll:number;interval:number}|null=null;
  app.post('/api/login/start',async()=>{
    ensure(hub.config.githubClientId,'github_client_id_required');
    const response=await fetch('https://github.com/login/device/code',{method:'POST',headers:{Accept:'application/json','Content-Type':'application/json'},body:JSON.stringify({client_id:hub.config.githubClientId,scope:'read:user'}),signal:AbortSignal.timeout(15000),redirect:'error'});
    ensure(response.ok,'login_failed');const data=await response.json() as {device_code:string;user_code:string;verification_uri:string;expires_in:number;interval:number};
    ensure(data.device_code&&data.verification_uri==='https://github.com/login/device','login_failed');
    login={code:data.device_code,expiresAt:Date.now()+data.expires_in*1000,nextPoll:Date.now()+data.interval*1000,interval:data.interval*1000};
    return {userCode:data.user_code,verificationUrl:data.verification_uri,expiresIn:data.expires_in};
  });
  app.post('/api/login/poll',async()=>{
    ensure(login&&Date.now()<login.expiresAt,'login_expired');if(Date.now()<login.nextPoll)return {pending:true};login.nextPoll=Date.now()+login.interval;
    const response=await fetch('https://github.com/login/oauth/access_token',{method:'POST',headers:{Accept:'application/json','Content-Type':'application/json'},body:JSON.stringify({client_id:hub.config.githubClientId,device_code:login.code,grant_type:'urn:ietf:params:oauth:grant-type:device_code'}),signal:AbortSignal.timeout(15000),redirect:'error'});
    const result=await response.json() as {access_token?:string;error?:string;expires_in?:number};
    if(result.error==='authorization_pending')return {pending:true};
    if(result.error==='slow_down'){login.interval+=5000;return {pending:true};}
    ensure(result.access_token,'login_failed');await writeSecret('cloud-github-token',result.access_token);login=null;return {signedIn:true};
  });
  app.post('/api/enroll',async()=>{
    ensure(hub.config.cloudUrl,'cloud_configuration_required');
    const {publicKey,privateKey}=generateKeyPairSync('ed25519');const publicPem=publicKey.export({type:'spki',format:'pem'}).toString();const privatePem=privateKey.export({type:'pkcs8',format:'pem'}).toString();
    await writeSecret(`device-${hub.config.deviceId}`,Buffer.from(privatePem).toString('base64'));
    try{await hub.request(`/workspaces/${hub.config.workspaceId}`);}catch(error){if(error instanceof DomainError&&error.code==='workspace_not_found')await hub.request('/workspaces','POST',{id:hub.config.workspaceId});else throw error;}
    await hub.execute({type:'device.register',id:hub.config.deviceId,name:'このMac',publicKey:publicPem});return {enrolled:true};
  });
  app.post('/api/refresh',async()=>{await hub.refresh();return {online:hub.online,error:hub.lastError};});
  return app;
}
