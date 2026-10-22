import {spawn,execFile} from 'node:child_process';
import {readFile} from 'node:fs/promises';
import {homedir,userInfo} from 'node:os';
import {join} from 'node:path';
import {z} from 'zod';
import {executable,terminalEnvironment} from './terminals.ts';

export interface UsageWindow {label:string; usedPercent:number; resetsAt:string|null}
export interface ProviderUsage {provider:'codex'|'claude'; status:'available'|'unavailable'|'signed_out'|'unsupported'; windows:UsageWindow[]; checkedAt:string}
type Reader=()=>Promise<UsageWindow[]>;
class UsageError extends Error {constructor(readonly status:ProviderUsage['status']){super(status);}}
const percent=z.number().finite().nonnegative();
const codexWindow=z.object({usedPercent:percent,windowDurationMins:z.number().positive().nullish(),resetsAt:z.number().nonnegative().nullish()});
const codexBucket=z.object({primary:codexWindow.nullish(),secondary:codexWindow.nullish(),limitId:z.string().nullish()});
const iso=(value:number)=>Number.isFinite(value)&&value<=8640000000000000?new Date(value).toISOString():null;

// account/rateLimits/read: https://learn.chatgpt.com/docs/app-server
export function parseCodexUsage(value:unknown):UsageWindow[] {
  const data=z.object({rateLimits:codexBucket.nullish(),rateLimitsByLimitId:z.record(z.string(),codexBucket).nullish()}).parse(value);
  const bucket=data.rateLimitsByLimitId?.codex??(data.rateLimits?.limitId==null||data.rateLimits.limitId==='codex'?data.rateLimits:undefined);
  return [bucket?.primary,bucket?.secondary].flatMap((window,index)=>{
    if(!window)return [];
    const minutes=window.windowDurationMins;
    const label=minutes===10080?'週':minutes&&minutes%60===0?`${minutes/60}h`:minutes?`${minutes}m`:index===0?'短期':'長期';
    return [{label,usedPercent:window.usedPercent,resetsAt:window.resetsAt==null?null:iso(window.resetsAt*1000)}];
  });
}

export async function readCodexUsage(program?:string):Promise<UsageWindow[]> {
  program??=await executable('codex');
  return new Promise((resolve,reject)=>{
    // No thread/turn is created. This process only reads account quota.
    const child=spawn(program!,['app-server','--listen','stdio://'],{cwd:homedir(),env:terminalEnvironment(),stdio:['pipe','pipe','ignore']});
    let buffer='',done=false,initialized=false;
    const finish=(error?:Error,value?:UsageWindow[])=>{
      if(done)return;done=true;clearTimeout(timer);child.stdin.destroy();child.kill('SIGTERM');
      const kill=setTimeout(()=>{if(child.exitCode===null&&child.signalCode===null)child.kill('SIGKILL');},1000);kill.unref();
      if(error)reject(error);else resolve(value??[]);
    };
    const timer=setTimeout(()=>finish(new UsageError('unavailable')),10000);
    const send=(message:unknown)=>child.stdin.write(JSON.stringify(message)+'\n');
    child.on('error',()=>finish(new UsageError('unavailable')));
    child.on('exit',()=>finish(new UsageError('unavailable')));
    child.stdin.on('error',()=>finish(new UsageError('unavailable')));
    child.stdout.setEncoding('utf8');
    child.stdout.on('data',(chunk:string)=>{
      if(done)return;
      buffer+=chunk;if(buffer.length>1024*1024){finish(new UsageError('unavailable'));return;}
      let end:number;
      while(!done&&(end=buffer.indexOf('\n'))>=0){
        const line=buffer.slice(0,end);buffer=buffer.slice(end+1);
        try {
          const message=JSON.parse(line);
          if(message.id!==1&&message.id!==2)continue;
          if(message.error){finish(new UsageError('unavailable'));return;}
          if(message.id===1&&!initialized){initialized=true;send({method:'initialized'});send({id:2,method:'account/rateLimits/read'});}
          else if(message.id===2)finish(undefined,parseCodexUsage(message.result));
        }catch{finish(new UsageError('unavailable'));}
      }
    });
    send({id:1,method:'initialize',params:{clientInfo:{name:'neuraos_usage',title:'neuraOS usage',version:'0.2.0'}}});
  });
}

const claudeWindow=z.object({utilization:percent,resets_at:z.string().nullish()});
export function parseClaudeUsage(value:unknown):UsageWindow[] {
  const data=z.object({five_hour:claudeWindow.nullish(),seven_day:claudeWindow.nullish()}).parse(value);
  return ([['5h',data.five_hour],['週',data.seven_day]] as const).flatMap(([label,window])=>window?[{
    label,usedPercent:window.utilization,resetsAt:window.resets_at?iso(Date.parse(window.resets_at)):null,
  }]:[]);
}

async function claudeAccessToken():Promise<string> {
  // Match the default login used by our terminal environment. Credentials never
  // enter snapshots, the operation journal, logs, or command-line arguments.
  let raw:string|undefined;
  if(process.platform==='darwin')raw=await new Promise<string|undefined>(resolve=>{
    execFile('/usr/bin/security',['find-generic-password','-s','Claude Code-credentials','-a',process.env.USER||userInfo().username,'-w'],{timeout:3000,maxBuffer:65536},(error,stdout)=>resolve(error?undefined:stdout));
  });
  if(!raw)raw=await readFile(join(homedir(),'.claude','.credentials.json'),'utf8').catch(()=>undefined);
  if(!raw)throw new UsageError('signed_out');
  const auth=z.object({claudeAiOauth:z.object({accessToken:z.string().min(1),expiresAt:z.number().optional()}).nullish()}).parse(JSON.parse(raw));
  if(!auth.claudeAiOauth||auth.claudeAiOauth.expiresAt!==undefined&&auth.claudeAiOauth.expiresAt<=Date.now())throw new UsageError('signed_out');
  return auth.claudeAiOauth.accessToken;
}

export async function readClaudeUsage(tokenReader=claudeAccessToken,request:typeof fetch=fetch):Promise<UsageWindow[]> {
  const token=await tokenReader();
  // Read-only endpoint used by Claude Code /usage. This is not a stable public
  // API: unknown schemas and failed requests must surface as unavailable.
  const response=await request('https://api.anthropic.com/api/oauth/usage',{
    headers:{Authorization:`Bearer ${token}`,'anthropic-beta':'oauth-2025-04-20'},
    redirect:'error',signal:AbortSignal.timeout(8000),
  });
  if(response.status===401)throw new UsageError('signed_out');
  if(!response.ok)throw new UsageError('unavailable');
  return parseClaudeUsage(await response.json());
}

export class ProviderUsageService {
  private cached:ProviderUsage[]=[];
  private nextRead=0;
  private pending:Promise<ProviderUsage[]>|undefined;
  constructor(private readers:{codex:Reader;claude:Reader}={codex:readCodexUsage,claude:readClaudeUsage},private interval=60000){}
  read():Promise<ProviderUsage[]> {
    if(this.pending)return this.pending;
    if(Date.now()<this.nextRead)return Promise.resolve(this.cached);
    this.pending=Promise.all((['codex','claude'] as const).map(async provider=>{
      let status:ProviderUsage['status']='available',windows:UsageWindow[]=[];
      try{windows=await this.readers[provider]();if(!windows.length)status='unsupported';}
      catch(error){status=error instanceof UsageError?error.status:'unavailable';}
      return {provider,status,windows,checkedAt:new Date().toISOString()};
    })).then(results=>{this.cached=results;this.nextRead=Date.now()+this.interval;return results;}).finally(()=>{this.pending=undefined;});
    return this.pending;
  }
  async close(){await this.pending;}
}
