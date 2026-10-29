//! Local inherited-pipe storage service. No network listener, credentials, or logging of data.
//! The writer owns SQLite; read queries run on an independent connection/thread.
use rusqlite::{params, Connection, types::Value as SqlValue};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{io::{self, BufRead, Read, Write}, sync::{mpsc, Arc, Mutex}, thread};

const SCHEMA: &str = "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA busy_timeout=5000;
CREATE TABLE IF NOT EXISTS agents(id TEXT PRIMARY KEY,data TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS projects(id TEXT PRIMARY KEY,data TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS workspaces(id TEXT PRIMARY KEY,data TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS terminals(id TEXT PRIMARY KEY,data TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS operations(id TEXT PRIMARY KEY,hash TEXT NOT NULL,status TEXT NOT NULL,result TEXT);
CREATE TABLE IF NOT EXISTS events(sequence INTEGER PRIMARY KEY AUTOINCREMENT,kind TEXT NOT NULL,entityId TEXT NOT NULL,at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS notification_events(sequence INTEGER PRIMARY KEY,terminalId TEXT NOT NULL,data TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS notification_terminal ON notification_events(terminalId);
CREATE TABLE IF NOT EXISTS output(sequence INTEGER PRIMARY KEY AUTOINCREMENT,terminalId TEXT NOT NULL,data TEXT NOT NULL,cols INTEGER,rows INTEGER);
CREATE INDEX IF NOT EXISTS output_terminal ON output(terminalId,sequence);";
#[derive(Deserialize)]
struct Request { id: u64, op: String, #[serde(default)] args: Value }
fn query(db: &Connection, sql: &str, args: &[Value]) -> Result<Value, String> {
    let mut statement=db.prepare(sql).map_err(|e|e.to_string())?;
    let names:Vec<String>=statement.column_names().iter().map(|s|s.to_string()).collect();
    let values=sql_values(args)?;
    let rows=statement.query_map(rusqlite::params_from_iter(values), |row| {
        let mut object=serde_json::Map::new();
        for (i,name) in names.iter().enumerate() {
            let value:SqlValue=row.get(i)?;
            object.insert(name.clone(),match value {SqlValue::Null=>Value::Null,SqlValue::Integer(n)=>json!(n),SqlValue::Real(n)=>json!(n),SqlValue::Text(s)=>Value::String(s),SqlValue::Blob(_)=>Value::Null});
        }
        Ok(Value::Object(object))
    }).map_err(|e|e.to_string())?;
    Ok(Value::Array(rows.collect::<rusqlite::Result<Vec<_>>>().map_err(|e|e.to_string())?))
}
fn sql_values(args: &[Value])->Result<Vec<SqlValue>,String>{args.iter().map(|v|match v {Value::Null=>Ok(SqlValue::Null),Value::String(s)=>Ok(SqlValue::Text(s.clone())),Value::Number(n)=>n.as_i64().map(SqlValue::Integer).ok_or("invalid integer".into()),_=>Err("invalid SQL value".into())}).collect()}
fn handle(db:&mut Connection,r:&Request)->Result<Value,String>{
    let a=&r.args;
    match r.op.as_str(){
        "snapshot"=>{
            let mut result=serde_json::Map::new();
            for table in ["projects","workspaces","terminals","agents"]{
                let rows=query(db,&format!("SELECT data FROM {table} ORDER BY rowid"),&[])?;
                let values:Result<Vec<Value>,_>=rows.as_array().unwrap().iter().map(|row|serde_json::from_str(row["data"].as_str().unwrap())).collect();
                result.insert(table.into(),json!(values.map_err(|e|e.to_string())?));
            }
            result.insert("revision".into(),query(db,"SELECT COALESCE(MAX(sequence),0) AS n FROM events",&[])?[0]["n"].clone());
            Ok(Value::Object(result))
        },
        "transaction"=>{
            let tx=db.transaction().map_err(|e|e.to_string())?;
            for item in a.as_array().ok_or("invalid transaction")?{
                let values=sql_values(item["args"].as_array().ok_or("invalid args")?)?;
                tx.execute(item["sql"].as_str().ok_or("invalid sql")?,rusqlite::params_from_iter(values)).map_err(|e|e.to_string())?;
            }
            tx.commit().map_err(|e|e.to_string())?;Ok(json!({}))
        },
        "append"=>{
            let tx=db.transaction().map_err(|e|e.to_string())?;
            {
                let mut insert=tx.prepare_cached("INSERT INTO output(terminalId,data,cols,rows) VALUES(?,?,?,?)").map_err(|e|e.to_string())?;
                for row in a.as_array().ok_or("invalid output")?{
                    insert.execute(params![row["terminalId"].as_str(),row["data"].as_str(),row["cols"].as_i64(),row["rows"].as_i64()]).map_err(|e|e.to_string())?;
                }
            }
            tx.commit().map_err(|e|e.to_string())?;Ok(json!({}))
        },
        "output"=>{
            let after=a["after"].as_i64().ok_or("invalid cursor")?;
            let mut stmt=db.prepare_cached("SELECT sequence,data,cols,rows FROM output WHERE terminalId=? AND sequence>? ORDER BY sequence LIMIT 256").map_err(|e|e.to_string())?;
            let mut rows=stmt.query(params![a["terminalId"].as_str(),after]).map_err(|e|e.to_string())?;
            let mut chunks=Vec::new();let mut bytes=0;let mut more=false;let mut cursor=after;
            while let Some(row)=rows.next().map_err(|e|e.to_string())?{
                if bytes>=256*1024 {more=true;break;}
                let data:String=row.get(1).map_err(|e|e.to_string())?;
                cursor=row.get(0).map_err(|e|e.to_string())?;bytes+=data.len();
                chunks.push(json!({"sequence":cursor,"data":data,"cols":row.get::<_,Option<i64>>(2).map_err(|e|e.to_string())?,"rows":row.get::<_,Option<i64>>(3).map_err(|e|e.to_string())?}));
            }
            more|=chunks.len()==256;
            let data:String=chunks.iter().map(|c|c["data"].as_str().unwrap()).collect();
            Ok(json!({"data":data,"chunks":chunks,"cursor":cursor,"more":more}))
        },
        "query"=>query(db,a["sql"].as_str().ok_or("invalid sql")?,a["args"].as_array().ok_or("invalid args")?),
        _=>Err("unknown operation".into())
    }
}
fn respond(out:&Arc<Mutex<io::Stdout>>,r:&Request,result:Result<Value,String>){
    // Error detail can contain SQL/data; expose a stable code only.
    let response=match result {Ok(value)=>json!({"id":r.id,"result":value}),Err(_)=>json!({"id":r.id,"error":"storage_failed"})};
    if let Ok(mut out)=out.lock(){if serde_json::to_writer(&mut *out,&response).is_err(){return;}let _=out.write_all(b"\n");let _=out.flush();}
}
fn run()->Result<(),Box<dyn std::error::Error>>{
    let path=std::env::args().nth(1).ok_or("missing database")?;
    let mut writer=Connection::open(&path)?;writer.execute_batch(SCHEMA)?;
    let columns:Vec<String>=writer.prepare("PRAGMA table_info(output)")?.query_map([],|r|r.get(1))?.collect::<rusqlite::Result<_>>()?;
    if !columns.iter().any(|c|c=="cols"){writer.execute_batch("ALTER TABLE output ADD COLUMN cols INTEGER; ALTER TABLE output ADD COLUMN rows INTEGER;")?;}
    let mut reader=Connection::open(&path)?;reader.execute_batch("PRAGMA query_only=ON; PRAGMA busy_timeout=5000;")?;
    let out=Arc::new(Mutex::new(io::stdout()));let output=out.clone();
    let (tx,rx)=mpsc::sync_channel::<Request>(8);
    let read_thread=thread::spawn(move||{for r in rx {let result=handle(&mut reader,&r);respond(&output,&r,result);}});
    // Parent pipe EOF closes both connections. No orphan socket service.
    let mut input=io::stdin().lock();
    loop {
        let mut line=Vec::new();
        let n=(&mut input).take(4*1024*1024+1).read_until(b'\n',&mut line)?;
        if n==0{break;}if line.len()>4*1024*1024||line.last()!=Some(&b'\n'){return Err("frame too large".into());}
        let r:Request=serde_json::from_slice(&line)?;
        if r.op=="output"||r.op=="query" {tx.send(r)?;}else{let result=handle(&mut writer,&r);respond(&out,&r,result);}
    }
    drop(tx);let _=read_thread.join();Ok(())
}
fn main(){if run().is_err(){eprintln!("native storage service failed");std::process::exit(1);}}
