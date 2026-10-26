import * as pty from 'node-pty';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';

import {access,realpath} from 'node:fs/promises';
import {constants} from 'node:fs';
import {homedir} from 'node:os';
import {join,delimiter} from 'node:path';
import {randomUUID} from 'node:crypto';
import {Fault,requireValue,type Provider,type TerminalRecord,type Workspace} from './contracts.ts';
import type {Store} from './store.ts';
import {ActivityTracker,activityArguments,activityBridge,supportsActivity,type ActivityBridge} from './agent-activity.ts';

const execFileAsync=promisify(execFile);

export function parseProcessTable(stdout:string){
  return stdout.trim().split('\n').filter(line=>line.trim()).map(line=>{
    const fields=line.trim().split(/\s+/);
    const [pid,parent,group]=fields.map(Number);
    if(fields.length!==3||!fields.every(field=>/^\d+$/.test(field))||
      ![pid,parent,group].every(Number.isSafeInteger)||pid<=0)
      throw new Fault('terminal_process_table_invalid','ターミナルの子プロセス一覧を確認できませんでした。もう一度削除してください。',409);
    // A system/exiting process may have PGID 0. It is a valid row, but must
    // never become a signal target (kill(0) targets the daemon's own group).
    return {pid,parent,group};
  });
}

async function readProcessTable(){
  try{return (await execFileAsync('/bin/ps',['-axo','pid=,ppid=,pgid='],{maxBuffer:8*1024*1024,timeout:5000})).stdout;}
  catch{throw new Fault('terminal_process_table_unavailable','ターミナルの子プロセス一覧を取得できませんでした。もう一度削除してください。',409);}
}

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
  private stoppingGroups=new Map<string,Set<number>>();
  private activity=new Map<string,{tracker:ActivityTracker;bridge:ActivityBridge}>();
  constructor(readonly store:Store,private processTable=readProcessTable){}
  async open(workspace:Workspace,provider:Provider,resume:boolean){
    const program=await executable(provider),id=randomUUID();
    const env=terminalEnvironment();
    let extraArgs:string[]=[];
    if(await supportsActivity(provider,program)){
      const tracker=new ActivityTracker();
      // Status integration is optional: a failed observer must not block the CLI.
      try{
        const bridge=await activityBridge(event=>{
          if(this.closing)return;
          const current=this.store.get<TerminalRecord>('terminals',id);
          if(!current||current.status!=='running')return;
          const activity=tracker.accept(event);
          const notification=tracker.notification?{id:randomUUID(),terminalId:id,workspaceId:current.workspaceId,provider:current.provider,kind:tracker.notification,createdAt:new Date().toISOString()}:undefined;
          if(current.activity!==activity||notification)this.store.put('terminals',{...current,activity},notification);
        });
        this.activity.set(id,{tracker,bridge});env.NEURA_ACTIVITY_SOCKET=bridge.path;
        extraArgs=activityArguments(provider);
      }catch{}
    }
    // Interactive user CLIs retain normal login/config, with full access selected at launch.
    let proc:pty.IPty;
    try{proc=pty.spawn(program,[...argumentsFor(provider,resume),...extraArgs],{cwd:workspace.path,env,name:'xterm-256color',cols:100,rows:30});}
    catch(error){await this.closeActivity(id);throw error;}
    const record:TerminalRecord={id,workspaceId:workspace.id,provider,status:'running',...(provider==='shell'?{}:{activity:'unknown' as const}),createdAt:new Date().toISOString(),cols:100,rows:30};
    this.processes.set(id,proc);this.store.put('terminals',record);this.store.resize(id,record.cols,record.rows);
    proc.onData(data=>{if(!this.closing)this.store.append(id,data);});
    proc.onExit(({exitCode})=>{this.processes.delete(id);this.owners.delete(id);void this.closeActivity(id);if(!this.closing)this.store.put('terminals',{...requireValue(this.store.get<TerminalRecord>('terminals',id),'terminal_missing','ターミナルがありません。'),status:'exited',activity:undefined,exitCode});});
    return record;
  }
  private async closeActivity(id:string){const entry=this.activity.get(id);this.activity.delete(id);await entry?.bridge.close().catch(()=>{});}
  private claim(id:string,clientId:string){
    const owner=this.owners.get(id);
    if(owner&&owner.clientId!==clientId&&owner.until>Date.now())throw new Fault('terminal_busy','別の画面で操作中です。操作終了から15秒後に入力できます。',409);
    this.owners.set(id,{clientId,until:Date.now()+15000});
  }
  input(id:string,clientId:string,data:string){const proc=requireValue(this.processes.get(id),'terminal_stopped','ターミナルは停止しています。');this.claim(id,clientId);proc.write(data);
    if(data==='\x03'||data==='\x1b'){
      const entry=this.activity.get(id),record=this.store.get<TerminalRecord>('terminals',id);
      if(entry&&record){entry.tracker.interrupt();if(record.activity!=='unknown')this.store.put('terminals',{...record,activity:'unknown'});}
    }
    return {ok:true};}
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
  async stopWorkspace(workspaceId:string){
    const ids=this.store.list<TerminalRecord>('terminals').filter(t=>t.workspaceId===workspaceId&&(t.status==='running'||this.stoppingGroups.has(t.id))).map(t=>t.id);
    await Promise.all(ids.map(async id=>{
      const proc=this.processes.get(id);
      // Preserve tracked groups across leader exit and a timed-out deletion retry.
      const groups=this.stoppingGroups.get(id)??new Set<number>();
      if(proc&&proc.pid>0)groups.add(proc.pid);
      if(!groups.size)throw new Fault('terminal_missing','ターミナルの停止状態を確認できません。',409);
      this.stoppingGroups.set(id,groups);
      const discoverGroups=async()=>{
        if(process.platform==='win32')return;
        // Interactive shells put foreground/background jobs in separate groups.
        // Capture descendants before signaling the shell; after reparenting, retain
        // their groups and discover any further descendants of surviving members.
        const rows=parseProcessTable(await this.processTable());
        const owned=new Set(rows.filter(row=>groups.has(row.group)).map(row=>row.pid));
        let changed=true;
        while(changed){
          changed=false;
          for(const row of rows)if(owned.has(row.parent)&&!owned.has(row.pid)){
            owned.add(row.pid);if(row.group>0)groups.add(row.group);changed=true;
          }
        }
      };
      const signaled={SIGHUP:new Set<number>(),SIGKILL:new Set<number>()};
      const signalGroup=(signal:'SIGHUP'|'SIGKILL')=>{
        if(process.platform==='win32'){if(this.processes.has(id))proc?.kill();return;}
        for(const group of groups){
          if(signaled[signal].has(group))continue;
          try{process.kill(-group,signal);}catch(error){if((error as NodeJS.ErrnoException).code!=='ESRCH')throw error;}
          signaled[signal].add(group);
        }
      };
      const groupAlive=()=>{
        if(process.platform==='win32')return this.processes.has(id);
        let alive=false;
        for(const group of groups)try{process.kill(-group,0);alive=true;}catch(error){
          if((error as NodeJS.ErrnoException).code!=='ESRCH')throw error;
        }
        return alive;
      };
      await discoverGroups();
      signalGroup('SIGHUP');
      const started=Date.now();
      // PTY exit only proves the leader exited, not its independent jobs.
      while(groupAlive()||this.processes.has(id)){
        const elapsed=Date.now()-started;
        await discoverGroups();
        signalGroup(elapsed>=1500?'SIGKILL':'SIGHUP');
        if(elapsed>=5000)throw new Fault('terminal_stop_timeout','ターミナルの終了を確認できません。もう一度削除してください。',409);
        await new Promise(resolve=>setTimeout(resolve,25));
      }
      this.stoppingGroups.delete(id);
    })).catch(error=>{
      if(error instanceof Fault)throw error;
      throw new Fault('terminal_stop_failed','ターミナルと子プロセスを停止できませんでした。作業フォルダは削除していません。ターミナルを停止してから、もう一度削除してください。',409);
    });
  }

  async shutdown(){this.closing=true;const processes=[...this.processes.values()];for(const proc of processes)this.kill(proc,'SIGHUP');if(processes.length)await new Promise(r=>setTimeout(r,250));for(const proc of processes)this.kill(proc,'SIGKILL');this.processes.clear();await Promise.all([...this.activity.keys()].map(id=>this.closeActivity(id)));}
}
