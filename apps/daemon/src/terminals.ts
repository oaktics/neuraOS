import * as pty from 'node-pty';
import {access,realpath} from 'node:fs/promises';
import {constants} from 'node:fs';
import {homedir} from 'node:os';
import {join,delimiter} from 'node:path';
import {randomUUID} from 'node:crypto';
import {Fault,requireValue,type Provider,type TerminalRecord,type Workspace} from './contracts.ts';
import type {Store} from './store.ts';

export async function executable(provider:Provider){
  if(provider==='shell')return process.platform==='win32'?'powershell.exe':'/bin/zsh';
  const override=process.env[provider==='codex'?'NEURA_CODEX_PATH':'NEURA_CLAUDE_PATH'];
  const paths=override?[override]:[join(homedir(),'.local/bin',provider),...['/opt/homebrew/bin','/usr/local/bin',...(process.env.PATH??'').split(delimiter)].map(dir=>join(dir,provider))];
  for(const path of paths)try{await access(path,constants.X_OK);return await realpath(path);}catch{}
  throw new Fault('provider_missing',`${provider==='codex'?'Codex':'Claude Code'}が見つかりません。CLIをインストールしてください。`);
}
export function argumentsFor(provider:Provider,resume:boolean){
  if(provider==='shell')return ['-l'];
  // Resume is the provider's own chooser. Do not guess a conversation from an unrelated directory.
  if(provider==='codex')return [...(resume?['resume']:[]),'--sandbox','danger-full-access','--ask-for-approval','never'];
  return [...(resume?['--resume']:[]),'--permission-mode','bypassPermissions'];
}
export function terminalEnvironment():Record<string,string>{
  return {HOME:homedir(),USER:process.env.USER??'',SHELL:'/bin/zsh',TERM:'xterm-256color',LANG:process.env.LANG??'en_US.UTF-8',PATH:[join(homedir(),'.local/bin'),'/opt/homebrew/bin','/usr/local/bin',process.env.PATH??'/usr/bin:/bin'].join(delimiter)};
}
export class Terminals {
  private processes=new Map<string,pty.IPty>();
  private owners=new Map<string,{clientId:string;until:number}>();
  private closing=false;
  constructor(readonly store:Store){}
  async open(workspace:Workspace,provider:Provider,resume:boolean){
    const program=await executable(provider),id=randomUUID();
    const env=terminalEnvironment();
    // Interactive user CLIs retain normal login/config, with full access selected at launch.
    const proc=pty.spawn(program,argumentsFor(provider,resume),{cwd:workspace.path,env,name:'xterm-256color',cols:100,rows:30});
    const record:TerminalRecord={id,workspaceId:workspace.id,provider,status:'running',createdAt:new Date().toISOString(),cols:100,rows:30};
    this.processes.set(id,proc);this.store.put('terminals',record);this.store.resize(id,record.cols,record.rows);
    proc.onData(data=>{if(!this.closing)this.store.append(id,data);});
    proc.onExit(({exitCode})=>{this.processes.delete(id);this.owners.delete(id);if(!this.closing)this.store.put('terminals',{...requireValue(this.store.get<TerminalRecord>('terminals',id),'terminal_missing','ターミナルがありません。'),status:'exited',exitCode});});
    return record;
  }
  private claim(id:string,clientId:string){
    const owner=this.owners.get(id);
    if(owner&&owner.clientId!==clientId&&owner.until>Date.now())throw new Fault('terminal_busy','別の画面で操作中です。操作終了から15秒後に入力できます。',409);
    this.owners.set(id,{clientId,until:Date.now()+15000});
  }
  input(id:string,clientId:string,data:string){const proc=requireValue(this.processes.get(id),'terminal_stopped','ターミナルは停止しています。');this.claim(id,clientId);proc.write(data);return {ok:true};}
  resize(id:string,clientId:string,cols:number,rows:number){
    const proc=requireValue(this.processes.get(id),'terminal_stopped','ターミナルは停止しています。');this.claim(id,clientId);
    const record=requireValue(this.store.get<TerminalRecord>('terminals',id),'terminal_missing','ターミナルがありません。');
    if(record.cols===cols&&record.rows===rows)return {ok:true};
    this.store.resize(id,cols,rows);proc.resize(cols,rows);
    this.store.put('terminals',{...record,cols,rows});return {ok:true};
  }
  private kill(proc:pty.IPty,signal:'SIGHUP'|'SIGKILL'){
    if(process.platform==='win32'){proc.kill();return;}
    // node-pty creates a separate session/process group. Stop that group, not the UI or daemon.
    try{process.kill(-proc.pid,signal);}catch(e){if((e as NodeJS.ErrnoException).code!=='ESRCH')proc.kill(signal);}
  }
  stop(id:string){const proc=this.processes.get(id);if(proc){this.kill(proc,'SIGHUP');const timer=setTimeout(()=>this.kill(proc,'SIGKILL'),1500);timer.unref();}return {ok:true};}
  async shutdown(){this.closing=true;const processes=[...this.processes.values()];for(const proc of processes)this.kill(proc,'SIGHUP');if(processes.length)await new Promise(r=>setTimeout(r,250));for(const proc of processes)this.kill(proc,'SIGKILL');this.processes.clear();}
}
