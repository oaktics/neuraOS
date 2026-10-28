import {DatabaseSync} from 'node:sqlite';
import {readdir,realpath} from 'node:fs/promises';
import {homedir} from 'node:os';
import {join,resolve} from 'node:path';
import {listSessions} from '@anthropic-ai/claude-agent-sdk';
import type {Provider,TerminalRecord,Workspace} from './contracts.ts';
import type {Store} from './store.ts';

interface SessionName {name:string; updatedAt:number}
type Readers = {codex:(path:string,sessionId?:string)=>Promise<SessionName|undefined>; claude:(path:string,sessionId?:string)=>Promise<SessionName|undefined>};

function displayName(value:unknown):string|undefined {
  if(typeof value!=='string')return;
  const name=value.replace(/[\p{Cc}\p{Cf}]/gu,' ').replace(/\s+/g,' ').trim();
  return name ? [...name].slice(0,200).join('') : undefined;
}

// The CLI's generated name is `name`, not `title` (which contains the first prompt).
// Read-only and fail-soft: missing/new provider schemas must not break the daemon.
export async function codexSessionName(path:string,codexHome=join(homedir(),'.codex'),sessionId?:string):Promise<SessionName|undefined> {
  const canonical=await realpath(path).catch(()=>resolve(path));
  const files=(await readdir(codexHome)).filter(f=>/^state_\d+\.sqlite$/.test(f)).sort((a,b)=>Number(b.match(/\d+/)![0])-Number(a.match(/\d+/)![0]));
  if(!files[0])return;
  const db=new DatabaseSync(join(codexHome,files[0]),{readOnly:true});
  try {
    db.exec('PRAGMA busy_timeout=50');
    const row=db.prepare("SELECT name, COALESCE(updated_at_ms, updated_at * 1000) AS updatedAt FROM threads WHERE cwd IN (?,?) AND (source='cli' OR id=?) AND archived=0 AND (? IS NULL OR id=?) ORDER BY updatedAt DESC, id DESC LIMIT 1").get(path,canonical,sessionId??null,sessionId??null,sessionId??null);
    const name=displayName(row?.name);
    if(name&&typeof row?.updatedAt==='number')return {name,updatedAt:row.updatedAt};
  } finally {db.close();}
}

export async function claudeSessionName(path:string,readSessions=listSessions,sessionId?:string):Promise<SessionName|undefined> {
  const canonical=await realpath(path).catch(()=>resolve(path));
  const sessions=await readSessions({dir:path,includeWorktrees:false,includeProgrammatic:false});
  // Encoded project-directory names can collide. Verify the original cwd too.
  const session=sessions.filter(s=>(!sessionId||s.sessionId===sessionId)&&s.cwd&&[resolve(path),canonical].includes(resolve(s.cwd))).sort((a,b)=>b.lastModified-a.lastModified)[0];
  // SDK 0.3.306 exposes custom-title OR ai-title here. summary may be a raw prompt.
  const name=displayName(session?.customTitle);
  if(name&&session)return {name,updatedAt:session.lastModified};
}

export class SessionNames {
  private pending:Promise<void>|undefined;
  private refreshedAt=0;
  private observedTerminals:Map<string,TerminalRecord['status']>;
  private names=new Map<string,SessionName>();
  constructor(private store:Store,private readers:Readers={codex:(path,id)=>codexSessionName(path,undefined,id),claude:(path,id)=>claudeSessionName(path,undefined,id)},private interval=3000){
    // Already stopped terminals (including those interrupted by a daemon restart)
    // keep their persisted workspace name without re-reading provider history.
    this.observedTerminals=new Map(store.list<TerminalRecord>('terminals').map(t=>[t.id,t.status]));
  }
  refresh():Promise<void> {
    if(this.pending)return this.pending;
    if(Date.now()-this.refreshedAt<this.interval)return Promise.resolve();
    this.pending=this.update().finally(()=>{this.refreshedAt=Date.now();this.pending=undefined;});
    return this.pending;
  }
  private async update() {
    const terminals=this.store.list<TerminalRecord>('terminals');
    // Poll running CLIs and read once after exit to collect their final title.
    // A newly observed stopped terminal may have run entirely between polls.
    const refreshable=terminals.filter(t=>t.status==='running'||!this.observedTerminals.has(t.id)||this.observedTerminals.get(t.id)==='running');
    this.observedTerminals=new Map(terminals.map(t=>[t.id,t.status]));
    // Exact session identity is required: newest-in-directory belongs to another tab.
    await Promise.all(refreshable.map(async terminal=>{
      if(!terminal.sessionId||terminal.provider==='shell')return;
      const workspace=this.store.get<Workspace>('workspaces',terminal.workspaceId);
      if(!workspace)return;
      const result=await this.readers[terminal.provider](workspace.path,terminal.sessionId).catch(()=>undefined);
      const name=displayName(result?.name),current=this.store.get<TerminalRecord>('terminals',terminal.id);
      // A resume/clear or exit can occur while the provider lookup is in flight.
      if(name&&current&&current.sessionId===terminal.sessionId&&current.sessionName!==name)
        this.store.put('terminals',{...current,sessionName:name});
    }));
    await Promise.all(this.store.list<Workspace>('workspaces').filter(w=>w.kind==='worktree').map(async workspace=>{
      const providers=new Set<Provider>(refreshable.filter(t=>t.workspaceId===workspace.id).map(t=>t.provider));
      const active=(['codex','claude'] as const).filter(p=>providers.has(p));
      if(!active.length)return;
      await Promise.all(active.map(async provider=>{
        const managed=refreshable.filter(t=>t.workspaceId===workspace.id&&t.provider===provider&&t.agentId&&t.sessionId);
        const candidates=await Promise.all([this.readers[provider](workspace.path).catch(()=>undefined),...managed.map(t=>this.readers[provider](workspace.path,t.sessionId).catch(()=>undefined))]);
        const name=candidates.filter((n):n is SessionName=>!!n).sort((a,b)=>b.updatedAt-a.updatedAt)[0];
        if(name&&displayName(name.name)&&Number.isFinite(name.updatedAt))this.names.set(`${workspace.id}:${provider}`,name);
      }));
      // Retain stopped providers' last title so an older title from another
      // running provider cannot replace it merely because polling stopped.
      const names=(['codex','claude'] as const).map(provider=>this.names.get(`${workspace.id}:${provider}`));
      const latest=names.filter((n):n is SessionName=>!!n&&Number.isFinite(n.updatedAt)).sort((a,b)=>b.updatedAt-a.updatedAt)[0];
      const name=displayName(latest?.name),current=this.store.get<Workspace>('workspaces',workspace.id);
      if(name&&current&&current.name!==name)this.store.put('workspaces',{...current,name});
    }));
  }
  async close(){await this.pending;}
}
