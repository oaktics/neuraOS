import {DatabaseSync} from 'node:sqlite';
import {createHash} from 'node:crypto';
import type {Project, Workspace, TerminalRecord} from './contracts.ts';

export const hash = (value:string) => createHash('sha256').update(value).digest('hex');
export class Store {
  readonly db:DatabaseSync;
  constructor(path:string){
    this.db=new DatabaseSync(path);
    this.db.exec(`PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA busy_timeout=5000;
      CREATE TABLE IF NOT EXISTS projects(id TEXT PRIMARY KEY, data TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS workspaces(id TEXT PRIMARY KEY, data TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS terminals(id TEXT PRIMARY KEY, data TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS operations(id TEXT PRIMARY KEY, hash TEXT NOT NULL, status TEXT NOT NULL, result TEXT);
      CREATE TABLE IF NOT EXISTS events(sequence INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, entityId TEXT NOT NULL, at TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS output(sequence INTEGER PRIMARY KEY AUTOINCREMENT, terminalId TEXT NOT NULL, data TEXT NOT NULL);
      CREATE INDEX IF NOT EXISTS output_terminal ON output(terminalId,sequence);`);
    const columns=this.db.prepare('PRAGMA table_info(output)').all();
    if(!columns.some(c=>c.name==='cols'))this.db.exec('ALTER TABLE output ADD COLUMN cols INTEGER; ALTER TABLE output ADD COLUMN rows INTEGER;');
    for(const t of this.list<TerminalRecord>('terminals'))if(t.status==='running')this.put('terminals',{...t,status:'interrupted'});
  }
  list<T>(table:'projects'|'workspaces'|'terminals'):T[]{return this.db.prepare(`SELECT data FROM ${table} ORDER BY rowid`).all().map(r=>JSON.parse(r.data as string));}
  get<T>(table:'projects'|'workspaces'|'terminals',id:string):T|undefined {const r=this.db.prepare(`SELECT data FROM ${table} WHERE id=?`).get(id);return r?JSON.parse(r.data as string):undefined;}
  put<T extends {id:string}>(table:'projects'|'workspaces'|'terminals',value:T){
    this.db.exec('BEGIN IMMEDIATE');try{
      this.db.prepare(`INSERT INTO ${table}(id,data) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data`).run(value.id,JSON.stringify(value));
      this.db.prepare('INSERT INTO events(kind,entityId,at) VALUES(?,?,?)').run(table,value.id,new Date().toISOString());
      this.db.exec('COMMIT');
    }catch(e){this.db.exec('ROLLBACK');throw e;}
  }
  state(){return {protocolVersion:1,hostName:process.env.NEURA_HOST_NAME??'このMac',revision:Number(this.db.prepare('SELECT COALESCE(MAX(sequence),0) AS n FROM events').get()!.n),projects:this.list<Project>('projects'),workspaces:this.list<Workspace>('workspaces'),terminals:this.list<TerminalRecord>('terminals')};}
  append(terminalId:string,data:string){this.db.prepare('INSERT INTO output(terminalId,data) VALUES(?,?)').run(terminalId,data);}
  resize(terminalId:string,cols:number,rows:number){this.db.prepare('INSERT INTO output(terminalId,data,cols,rows) VALUES(?,?,?,?)').run(terminalId,'',cols,rows);}
  output(terminalId:string,after:number){
    const rows=this.db.prepare('SELECT sequence,data,cols,rows FROM output WHERE terminalId=? AND sequence>? ORDER BY sequence LIMIT 256').all(terminalId,after);
    return {data:rows.map(r=>r.data).join(''),chunks:rows,cursor:rows.length?Number(rows.at(-1)!.sequence):after,more:rows.length===256};
  }
  close(){this.db.close();}
}
