import { randomUUID, sign } from 'node:crypto';
import type { Actor, Command, Envelope, State } from '../../../packages/contracts/src/index.ts';
import { LocalStore } from '../../../packages/sync/src/local-store.ts';
import { canonical, DomainError, ensure } from '../../../packages/policy/src/index.ts';
import { readSecret, writeSecret } from '../../../packages/connectors/src/secrets.ts';
export interface RunnerConfig {dataDir:string;workspaceId:string;deviceId:string;port:number;cloudUrl:string|null;githubClientId:string|null;allowFixtures:boolean}
export class Hub {
  online=false;lastError='';private tail:Promise<unknown>=Promise.resolve();
  constructor(readonly store:LocalStore,readonly config:RunnerConfig){}
  read(){return this.store.read();}
  private async token(){
    const token=await readSecret('cloud-github-token');ensure(token,'cloud_login_required');return token;
  }
  async request(path:string,method='GET',body?:unknown,asRunner=false){
    ensure(this.config.cloudUrl?.startsWith('https://'),'cloud_tls_required');
    const headers:Record<string,string>={authorization:`Bearer ${await this.token()}`,'content-type':'application/json'};
    if(asRunner){const key=await readSecret(`device-${this.config.deviceId}`);ensure(key,'device_key_missing');const time=String(Date.now());headers['x-neura-device']=this.config.deviceId;headers['x-neura-time']=time;headers['x-neura-signature']=sign(null,Buffer.from(canonical({method,url:path,time,body:body??null})),Buffer.from(key,'base64').toString()).toString('base64');}
    const response=await fetch(this.config.cloudUrl+path,{method,headers,body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(15000),redirect:'error'});
    if(!response.ok){const error=await response.json().catch(()=>({error:'cloud_request_failed'})) as {error:string};throw new DomainError(error.error,error.error,response.status);}
    return response.json() as Promise<State>;
  }
  private serialize<T>(fn:()=>Promise<T>):Promise<T>{const result=this.tail.then(fn,fn);this.tail=result.catch(()=>{});return result;}
  actor(role:'user'|'runner'|'scheduler'):Actor{return {id:role==='runner'?this.config.deviceId:'local-owner',role,...(role==='runner'?{deviceId:this.config.deviceId}:{})};}
  async execute(command:Command,role:'user'|'runner'|'scheduler'='user',operationId:string=randomUUID()):Promise<State>{return this.serialize(async()=>{
    const e={operationId,command};
    if(!this.config.cloudUrl){const s=this.store.apply(e,this.actor(role));this.online=false;return s;}
    // Prevent local-only payloads at the sender, before HTTPS transmission.
    if('input' in command&&command.input&&'classification' in command.input){ensure(command.input.classification!=='local-only','local_only_requires_local_draft');if('sources' in command.input)ensure(command.input.sources.every(s=>s.classification!=='local-only'),'local_only_requires_local_draft');}
    if('classification' in command)ensure(command.classification!=='local-only','local_only_requires_local_draft');
    if(role==='scheduler')return this.read(); // The cloud scheduler owns scheduled state.
    if(command.type==='run.event')this.store.enqueue(e);
    try{const s=await this.request(`/workspaces/${this.config.workspaceId}/commands`,'POST',e,role==='runner');this.store.acknowledge(operationId,s);this.online=true;this.lastError='';return s;}
    catch(error){this.lastError=error instanceof DomainError?error.code:'cloud_disconnected';this.online=false;
      if(error instanceof DomainError&&error.status<500)this.store.reject(operationId,error.code);
      if(command.type==='run.event'&&!(error instanceof DomainError))return this.read();throw error;
    }
  });}
  async refresh():Promise<State>{return this.serialize(async()=>{
    if(!this.config.cloudUrl)return this.read();
    try{
      for(const e of this.store.pending()){try{const s=await this.request(`/workspaces/${this.config.workspaceId}/commands`,'POST',e,true);this.store.acknowledge(e.operationId,s);}catch(err){if(err instanceof DomainError&&err.status<500)this.store.reject(e.operationId,err.code);else throw err;}}
      const s=await this.request(`/workspaces/${this.config.workspaceId}`,'GET',undefined,true);this.store.transaction(()=>this.store.write(s));this.online=true;this.lastError='';return this.read();
    }catch(error){this.online=false;this.lastError=error instanceof DomainError?error.code:'cloud_disconnected';return this.read();}
  });}
  async archive(artifactId:string){ensure(this.config.cloudUrl&&this.online,'cloud_unavailable');return this.serialize(async()=>{const s=await this.request(`/workspaces/${this.config.workspaceId}/artifacts/${artifactId}/store`,'POST',{},true);this.store.transaction(()=>this.store.write(s));return s;});}
}
