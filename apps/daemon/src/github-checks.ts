import {z} from 'zod';
import {Fault} from './contracts.ts';

export interface CICheck {name:string;state:string;url:string|null}
export type CIState='running'|'success'|'failure'|'cancelled'|'none'|'unpublished'|'unknown'|'unavailable'|'unsupported';
export interface CISnapshot {state:CIState;checks:CICheck[];head?:string;repository?:string;fetchedAt:string;message?:string}

export function summarizeChecks(checks:CICheck[]):CIState {
  const states=checks.map(c=>c.state);
  if(!states.length)return 'none';
  if(states.some(s=>['FAILURE','ERROR','TIMED_OUT','ACTION_REQUIRED','STARTUP_FAILURE','STALE'].includes(s)))return 'failure';
  if(states.some(s=>['PENDING','QUEUED','IN_PROGRESS','WAITING','REQUESTED','EXPECTED'].includes(s)))return 'running';
  if(states.includes('CANCELLED'))return 'cancelled';
  if(states.every(s=>['SUCCESS','NEUTRAL','SKIPPED'].includes(s)))return 'success';
  return 'unknown';
}

const node=z.object({name:z.string().optional(),context:z.string().optional(),status:z.string().optional(),conclusion:z.string().nullable().optional(),state:z.string().optional(),detailsUrl:z.string().nullable().optional(),targetUrl:z.string().nullable().optional()});
const pages=z.array(z.object({data:z.object({repository:z.object({object:z.object({oid:z.string(),statusCheckRollup:z.object({contexts:z.object({nodes:z.array(node)})}).nullable()}).nullable()}).nullable()})}));
export function parseChecks(value:unknown,head:string):Pick<CISnapshot,'state'|'checks'> {
  const parsed=pages.parse(value);
  if(!parsed.length||parsed.some(p=>!p.data.repository))throw new Fault('github_missing','GitHub リポジトリを取得できません。');
  const commits=parsed.map(p=>p.data.repository!.object);
  if(commits.every(c=>!c))return {state:'unpublished',checks:[]};
  if(commits.some(c=>!c||c.oid!==head))throw new Fault('github_head','CI のコミットを確認できません。');
  const checks=commits.flatMap(c=>c?.statusCheckRollup?.contexts.nodes??[]).map(c=>({name:c.name??c.context??'チェック',state:c.conclusion||c.status||c.state||'UNKNOWN',url:c.detailsUrl||c.targetUrl||null}));
  return {state:summarizeChecks(checks),checks};
}

// Coalesce reads by repository + exact commit; bound both network concurrency
// and cache size. Errors have a cooldown too, so signed-out clients don't retry
// for every worktree every time the sidebar is reconstructed.
export class ChecksCache {
  private entries=new Map<string,{expires:number;result:Promise<CISnapshot>}>();
  private active=0;
  private waiting:Array<()=>void>=[];
  constructor(private ttl=60000){}
  async read(key:string,fetch:()=>Promise<CISnapshot>):Promise<CISnapshot>{
    const existing=this.entries.get(key);
    if(existing&&existing.expires>Date.now())return existing.result;
    const entry={expires:Infinity,result:Promise.resolve({} as CISnapshot)};
    entry.result=this.limited(fetch).catch(error=>({state:'unavailable' as const,checks:[],fetchedAt:new Date().toISOString(),message:error instanceof Fault?error.message:'GitHub のCIを取得できません。'})).finally(()=>{entry.expires=Date.now()+this.ttl;});
    this.entries.set(key,entry);
    for(const [old,value] of this.entries){if(this.entries.size<=256)break;if(value.expires!==Infinity)this.entries.delete(old);}
    return entry.result;
  }
  invalidate(prefix:string){for(const key of this.entries.keys())if(key.startsWith(prefix))this.entries.delete(key);}
  private async limited(fetch:()=>Promise<CISnapshot>):Promise<CISnapshot>{
    if(this.active>=4)await new Promise<void>(resolve=>this.waiting.push(resolve));
    else this.active++;
    try{return await fetch();}
    finally{const next=this.waiting.shift();if(next)next();else this.active--;}
  }
}
