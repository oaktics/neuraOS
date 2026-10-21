import { DatabaseSync } from 'node:sqlite';
import { mkdirSync, chmodSync } from 'node:fs';
import { dirname } from 'node:path';
import type { Actor, Envelope, State } from '../../contracts/src/index.ts';
import { applyCommand, emptyState } from '../../task-domain/src/index.ts';

/** Execution journal + outbox share a SQLite WAL transaction. */
export class LocalStore {
  readonly db:DatabaseSync;
  constructor(path:string,workspaceId:string){
    mkdirSync(dirname(path),{recursive:true,mode:0o700});this.db=new DatabaseSync(path);chmodSync(path,0o600);
    this.db.exec(`PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA secure_delete=ON; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;
      CREATE TABLE IF NOT EXISTS snapshot(id INTEGER PRIMARY KEY CHECK(id=1),payload TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS journal(operation_id TEXT PRIMARY KEY,payload TEXT NOT NULL,created_at TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS outbox(operation_id TEXT PRIMARY KEY REFERENCES journal(operation_id),acked INTEGER NOT NULL DEFAULT 0,error TEXT);
      CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS drafts(id TEXT PRIMARY KEY,payload TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS tombstones(id TEXT PRIMARY KEY,deleted_at TEXT NOT NULL);`);
    this.db.prepare('INSERT OR IGNORE INTO snapshot VALUES(1,?)').run(JSON.stringify(emptyState(workspaceId)));
  }
  read():State{return JSON.parse((this.db.prepare('SELECT payload FROM snapshot WHERE id=1').get() as {payload:string}).payload);}
  transaction<T>(fn:()=>T):T{this.db.exec('BEGIN IMMEDIATE');try{const r=fn();this.db.exec('COMMIT');return r;}catch(e){this.db.exec('ROLLBACK');throw e;}}
  write(state:State){
    // Durable deletion ledger survives importing an older backup.
    for(const t of state.tombstones)this.db.prepare('INSERT OR IGNORE INTO tombstones VALUES(?,?)').run(t.id,t.deletedAt);
    const deleted=this.db.prepare('SELECT id,deleted_at FROM tombstones').all() as {id:string;deleted_at:string}[];
    const clean=structuredClone(state);clean.memories=clean.memories.filter(m=>!deleted.some(d=>d.id===m.id));
    for(const d of deleted)if(!clean.tombstones.some(t=>t.id===d.id))clean.tombstones.push({id:d.id,deletedAt:d.deleted_at});
    this.db.prepare('UPDATE snapshot SET payload=? WHERE id=1').run(JSON.stringify(clean));
    // Purge deleted memory bodies from the transport journal, retaining only operation IDs in state.
    for(const d of deleted){
      this.db.prepare("DELETE FROM outbox WHERE operation_id IN (SELECT operation_id FROM journal WHERE json_extract(payload,'$.command.id')=?)").run(d.id);
      this.db.prepare("DELETE FROM journal WHERE json_extract(payload,'$.command.id')=?").run(d.id);
    }
  }
  apply(envelope:Envelope,actor:Actor,now?:Date):State{return this.transaction(()=>{const state=applyCommand(this.read(),envelope,actor,now);this.write(state);return state;});}
  enqueue(envelope:Envelope){this.transaction(()=>{
    this.db.prepare('INSERT OR IGNORE INTO journal VALUES(?,?,?)').run(envelope.operationId,JSON.stringify(envelope),new Date().toISOString());
    this.db.prepare('INSERT OR IGNORE INTO outbox(operation_id) VALUES(?)').run(envelope.operationId);
  });}
  pending():Envelope[]{return (this.db.prepare('SELECT j.payload FROM journal j JOIN outbox o USING(operation_id) WHERE o.acked=0 AND o.error IS NULL ORDER BY j.rowid').all() as {payload:string}[]).map(x=>JSON.parse(x.payload));}
  acknowledge(id:string,state:State){this.transaction(()=>{this.write(state);this.db.prepare('UPDATE outbox SET acked=1 WHERE operation_id=?').run(id);});}
  reject(id:string,code:string){this.db.prepare('UPDATE outbox SET error=? WHERE operation_id=?').run(code,id);}
  meta(key:string):string|undefined{return (this.db.prepare('SELECT value FROM metadata WHERE key=?').get(key) as {value:string}|undefined)?.value;}
  setMeta(key:string,value:string){this.db.prepare('INSERT INTO metadata VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value').run(key,value);}
  close(){this.db.close();}
}
