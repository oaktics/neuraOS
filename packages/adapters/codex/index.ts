import { spawn, execFile, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { promisify } from 'node:util';
import { createInterface } from 'node:readline';
import { mkdir } from 'node:fs/promises';
import { join } from 'node:path';
import { AgentOutput, AgentOutputJsonSchema } from '../../contracts/src/index.ts';
import type { AgentAdapter, AdapterContext, Capabilities, AdapterResult } from '../index.ts';
import {chatTextEmitter} from '../chat-stream.ts';
import { buildPrompt } from '../index.ts';
import { providerAuth } from '../local-auth.ts';
import { DomainError, ensure } from '../../policy/src/index.ts';
import { inferenceProxy } from '../proxy.ts';
import { spawnIsolated, stopProcessGroup } from '../../execution/src/sandbox.ts';
const exec=promisify(execFile);
type RpcMessage={id?:number|string;method?:string;params?:any;result?:any;error?:{message:string}};
export class CodexRpc {
  private seq=0;private pending=new Map<number,{resolve:(v:any)=>void;reject:(e:Error)=>void;timer:NodeJS.Timeout}>();
  onNotification:(m:RpcMessage)=>void=()=>{};
  onRequest:(m:RpcMessage)=>void=(m)=>this.reply(m.id!,{decision:'decline'});
  constructor(readonly child:ChildProcessWithoutNullStreams){
    const lines=createInterface({input:child.stdout});lines.on('line',line=>{try{const m:RpcMessage=JSON.parse(line);if(m.method){if(m.id!==undefined)this.onRequest(m);else this.onNotification(m);}else if(typeof m.id==='number'){const p=this.pending.get(m.id);if(p){clearTimeout(p.timer);this.pending.delete(m.id);if(m.error)p.reject(new Error(m.error.message));else p.resolve(m.result);}}}catch{this.fail(new Error('invalid_codex_message'));}});
    child.on('error',e=>this.fail(e));child.on('exit',()=>this.fail(new Error('codex_exited')));child.stderr.resume();
  }
  private fail(e:Error){for(const p of this.pending.values()){clearTimeout(p.timer);p.reject(e);}this.pending.clear();}
  request(method:string,params:unknown):Promise<any>{const id=++this.seq;return new Promise((resolve,reject)=>{const timer=setTimeout(()=>{this.pending.delete(id);reject(new Error('codex_rpc_timeout'));},30000);this.pending.set(id,{resolve,reject,timer});this.child.stdin.write(JSON.stringify({id,method,params})+'\n');});}
  notify(method:string,params:unknown={}){this.child.stdin.write(JSON.stringify({method,params})+'\n');}
  reply(id:number|string,result:unknown){this.child.stdin.write(JSON.stringify({id,result})+'\n');}
  close(){this.fail(new Error('codex_closed'));stopProcessGroup(this.child);}
}
export class CodexAdapter implements AgentAdapter {
  constructor(private executable=process.env.NEURA_CODEX_PATH??'/opt/homebrew/bin/codex'){}
  async probeCapabilities():Promise<Capabilities>{let version='unavailable';try{version=(await exec(this.executable,['--version'])).stdout.trim();}catch{}
    return {provider:'codex',available:version!=='unavailable',resume:true,interrupt:true,structuredOutput:true,usage:true,approvals:true,isolation:process.platform==='darwin',version,reason:version==='unavailable'?'CLIが見つかりません':!(await providerAuth('codex'))?'端末で codex login を実行してください':''};}
  async execute(c:AdapterContext):Promise<AdapterResult>{
    const auth=await providerAuth('codex');ensure(auth,'codex_auth_missing');const key=auth.token;
    const proxy=await inferenceProxy('codex',key,c.allowance?.calls??Math.max(1,c.task.budget.maxCalls-(c.task.runs.at(-1)?.calls??1)+1),auth,c.allowance?{tokens:c.allowance.tokens}:undefined);const home=join(c.runtimeDir,'home');await mkdir(join(home,'.codex'),{recursive:true,mode:0o700});
    let rpc:CodexRpc|undefined;let threadId='';let turnId='';
    const abort=()=>{if(rpc&&threadId&&turnId)void rpc.request('turn/interrupt',{threadId,turnId}).catch(()=>{});if(rpc)stopProcessGroup(rpc.child);};
    try{
      const config:Record<string,unknown>={model_provider:'neura',model_providers:{neura:{name:'neuraOS gateway',base_url:proxy.url+'/v1',wire_api:'responses',requires_openai_auth:false}},features:{shell_tool:false,unified_exec:false,apps:false,plugins:false,multi_agent:false,memories:false,computer_use:false,browser_use:false,image_generation:false,view_image:false,hooks:false,code_mode_host:false},web_search:'disabled',mcp_servers:{},project_doc_max_bytes:0};
      const args=['app-server','--listen','stdio://','--strict-config','-c','cli_auth_credentials_store="file"','-c','features.shell_tool=false','-c','features.apps=false','-c','features.plugins=false','-c','features.shell_snapshot=false','-c','features.memories=false'];
      const child=await spawnIsolated(this.executable,args,c.runtimeDir,proxy.port,{PATH:'/usr/bin:/bin:/opt/homebrew/bin',HOME:home,CODEX_HOME:join(home,'.codex'),TMPDIR:home,LANG:'en_US.UTF-8'});rpc=new CodexRpc(child);
      await rpc.request('initialize',{clientInfo:{name:'neuraos',title:'neuraOS',version:'0.1.0'},capabilities:{experimentalApi:false}});rpc.notify('initialized');
      const prior=c.freshSession?undefined:c.task.runs.at(-1)?.sessionId;
      const session=await rpc.request(prior?'thread/resume':'thread/start',{...(prior?{threadId:prior}:{}),cwd:c.runtimeDir,model:c.task.model||undefined,approvalPolicy:'never',sandbox:'read-only',config,baseInstructions:'You produce structured artifacts. You have no host tools. All external actions are managed by neuraOS.'});
      threadId=session.thread.id;await c.onSession(threadId,session.model??c.task.model,'codex-app-server/0.163.0');
      let text='';let tokens=0;let events=Promise.resolve();const streamed=chatTextEmitter(c);const previousTokens=prior?(c.task.runs.at(-1)?.tokens??0):0;
      const result=new Promise<AdapterResult>((resolve,reject)=>{
        child.once('exit',()=>reject(new Error(c.signal.aborted?'interrupted':'codex_exited')));
        child.once('error',reject);
        rpc!.onNotification=m=>{
          if(m.params?.threadId&&m.params.threadId!==threadId)return;
          if(m.method==='item/agentMessage/delta'){text+=m.params.delta??'';streamed.push(text);}
          if(m.method==='item/completed'&&m.params.item?.type==='agentMessage')text=m.params.item.text??text;
          if(m.method==='thread/tokenUsage/updated')tokens=Math.max(m.params.tokenUsage?.last?.totalTokens??0,(m.params.tokenUsage?.total?.totalTokens??previousTokens)-previousTokens);
          if(m.method==='turn/completed'){
            if(m.params.turn.status!=='completed'){reject(new Error(`codex_turn_${m.params.turn.status}: ${m.params.turn.error?.message??'unknown provider error'}`));return;}
            events.then(()=>streamed.flush()).then(()=>{try{resolve({output:AgentOutput.parse(JSON.parse(text)),tokens,costUsd:null,calls:proxy.calls});}catch(e){reject(e);}},reject);
          }
        };
        rpc!.onRequest=m=>{rpc!.reply(m.id!,{decision:'decline'});events=events.then(()=>c.onEvent('permission.denied','ホスト操作要求を拒否しました。'));};
      });
      // Attach rejection before asynchronous turn startup to avoid unhandled child exits.
      result.catch(()=>{});
      c.signal.addEventListener('abort',abort,{once:true});if(c.signal.aborted)abort();
      const turn=await rpc.request('turn/start',{threadId,input:[{type:'text',text:buildPrompt(c),text_elements:[]}],outputSchema:AgentOutputJsonSchema});turnId=turn.turn.id;
      const completed=await result;return {...completed,tokens:proxy.measured?proxy.tokens:completed.tokens};
    }catch(error){if(proxy.budgetExceeded)throw Object.assign(new DomainError('token_budget'),{usage:proxy.measured?{tokens:proxy.tokens,calls:proxy.calls,costUsd:null}:undefined});throw error;}finally{c.signal.removeEventListener('abort',abort);rpc?.close();await proxy.close();}
  }
}
