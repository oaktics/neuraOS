import pg from 'pg';
import type { Actor, Envelope, State } from '../../../packages/contracts/src/index.ts';
import { applyCommand, emptyState } from '../../../packages/task-domain/src/index.ts';
import { ensure } from '../../../packages/policy/src/index.ts';
export class PostgresStore {
  constructor(readonly pool:pg.Pool){}
  async transaction<T>(userId:string,fn:(client:pg.PoolClient)=>Promise<T>):Promise<T>{const c=await this.pool.connect();try{await c.query('BEGIN');await c.query("SELECT set_config('neura.user_id',$1,true)",[userId]);const value=await fn(c);await c.query('COMMIT');return value;}catch(e){await c.query('ROLLBACK');throw e;}finally{c.release();}}
  async read(workspaceId:string,userId:string):Promise<State>{return this.transaction(userId,async c=>{const r=await c.query('SELECT state FROM neura_workspaces WHERE id=$1 AND owner_id=$2',[workspaceId,userId]);ensure(r.rows[0],'workspace_not_found');return r.rows[0].state;});}
  async create(workspaceId:string,userId:string){return this.transaction(userId,async c=>{const state=emptyState(workspaceId);await c.query('INSERT INTO neura_workspaces(id,owner_id,state) VALUES($1,$2,$3)',[workspaceId,userId,state]);return state;});}
  async apply(workspaceId:string,userId:string,envelope:Envelope,actor:Actor):Promise<State>{return this.transaction(userId,async c=>{
    const r=await c.query('SELECT state FROM neura_workspaces WHERE id=$1 AND owner_id=$2 FOR UPDATE',[workspaceId,userId]);ensure(r.rows[0],'workspace_not_found');
    const prior:State=r.rows[0].state;const state=applyCommand(prior,envelope,actor);
    if(state===prior)return prior;
    // local-only content must never enter this service, including through memory or project edits.
    ensure(!state.tasks.some(t=>t.classification==='local-only')&&!state.memories.some(m=>m.classification==='local-only')&&!state.projects.some(p=>p.classification==='local-only'),'local_only_cloud_forbidden');
    await c.query('UPDATE neura_workspaces SET state=$1,revision=$2,updated_at=now() WHERE id=$3 AND owner_id=$4',[state,state.revision,workspaceId,userId]);
    for(const a of state.audit.slice(prior.audit.length))await c.query('INSERT INTO neura_audit VALUES($1,$2,$3,$4,$5,$6,$7) ON CONFLICT DO NOTHING',[a.id,workspaceId,a.actor,a.operation,a.target,a.traceId,a.at]);
    await c.query('DELETE FROM neura_memory_search WHERE workspace_id=$1',[workspaceId]);
    for(const m of state.memories.filter(m=>m.state==='active'))await c.query('INSERT INTO neura_memory_search(id,workspace_id,content) VALUES($1,$2,$3)',[m.id,workspaceId,m.content]);
    for(const d of state.tombstones)await c.query('INSERT INTO neura_deletions VALUES($1,$2,$3) ON CONFLICT DO NOTHING',[workspaceId,d.id,d.deletedAt]);
    return state;
  });}
}
