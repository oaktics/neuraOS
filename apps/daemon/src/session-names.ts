import {DatabaseSync} from 'node:sqlite';
import {readdir,realpath} from 'node:fs/promises';
import {homedir} from 'node:os';
import {join,resolve} from 'node:path';
import {listSessions} from '@anthropic-ai/claude-agent-sdk';
import type {Provider,TerminalRecord,Workspace} from './contracts.ts';
import type {Store} from './store.ts';

interface SessionName {name:string; updatedAt:number}
type Readers = {codex:(path:string)=>Promise<SessionName|undefined>; claude:(path:string)=>Promise<SessionName|undefined>};

function displayName(value:unknown):string|undefined {
  if(typeof value!=='string')return;
  const name=value.replace(/[\p{Cc}\p{Cf}]/gu,' ').replace(/\s+/g,' ').trim();
  return name ? [...name].slice(0,200).join('') : undefined;
}

// The CLI's generated name is `name`, not `title` (which contains the first prompt).
// Read-only and fail-soft: missing/new provider schemas must not break the daemon.
export async function codexSessionName(path:string,codexHome=join(homedir(),'.codex')):Promise<SessionName|undefined> {
  const canonical=await realpath(path).catch(()=>resolve(path));
  const files=(await readdir(codexHome)).filter(f=>/^state_\d+\.sqlite$/.test(f)).sort((a,b)=>Number(b.match(/\d+/)![0])-Number(a.match(/\d+/)![0]));
  if(!files[0])return;
  const db=new DatabaseSync(join(codexHome,files[0]),{readOnly:true});
  try {
    db.exec('PRAGMA busy_timeout=50');
    const row=db.prepare("SELECT name, COALESCE(updated_at_ms, updated_at * 1000) AS updatedAt FROM threads WHERE cwd IN (?,?) AND source='cli' AND archived=0 ORDER BY updatedAt DESC, id DESC LIMIT 1").get(path,canonical);
    const name=displayName(row?.name);
    if(name&&typeof row?.updatedAt==='number')return {name,updatedAt:row.updatedAt};
  } finally {db.close();}
}

export async function claudeSessionName(path:string,readSessions=listSessions):Promise<SessionName|undefined> {
  const canonical=await realpath(path).catch(()=>resolve(path));
  const sessions=await readSessions({dir:path,includeWorktrees:false,includeProgrammatic:false});
  // Encoded project-directory names can collide. Verify the original cwd too.
  const session=sessions.filter(s=>s.cwd&&[resolve(path),canonical].includes(resolve(s.cwd))).sort((a,b)=>b.lastModified-a.lastModified)[0];
  // SDK 0.3.306 exposes custom-title OR ai-title here. summary may be a raw prompt.
  const name=displayName(session?.customTitle);
  if(name&&session)return {name,updatedAt:session.lastModified};
}

export class SessionNames {
  private pending:Promise<void>|undefined;
  private refreshedAt=0;
  constructor(private store:Store,private readers:Readers={codex:codexSessionName,claude:claudeSessionName},private interval=3000){}
  refresh():Promise<void> {
    if(this.pending)return this.pending;
    if(Date.now()-this.refreshedAt<this.interval)return Promise.resolve();
    this.pending=this.update().finally(()=>{this.refreshedAt=Date.now();this.pending=undefined;});
    return this.pending;
  }
  private async update() {
    const terminals=this.store.list<TerminalRecord>('terminals');
    await Promise.all(this.store.list<Workspace>('workspaces').filter(w=>w.kind==='worktree').map(async workspace=>{
      const providers=new Set<Provider>(terminals.filter(t=>t.workspaceId===workspace.id).map(t=>t.provider));
      const names=await Promise.all((['codex','claude'] as const).filter(p=>providers.has(p)).map(p=>this.readers[p](workspace.path).catch(()=>undefined)));
      const latest=names.filter((n):n is SessionName=>!!n&&Number.isFinite(n.updatedAt)).sort((a,b)=>b.updatedAt-a.updatedAt)[0];
      const name=displayName(latest?.name),current=this.store.get<Workspace>('workspaces',workspace.id);
      if(name&&current&&current.name!==name)this.store.put('workspaces',{...current,name});
    }));
  }
  async close(){await this.pending;}
}
