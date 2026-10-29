use crate::{error::ApiError, events::Change};
use rusqlite::{params, types::Value as SqlValue, Connection};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{path::Path, sync::Arc};
use tokio::sync::{broadcast, mpsc, oneshot, OwnedSemaphorePermit, Semaphore};
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
struct Request {
    op: String,
    #[serde(default)]
    args: Value,
}
fn query(db: &Connection, sql: &str, args: &[Value]) -> Result<Value, String> {
    let mut statement = db.prepare(sql).map_err(|e| e.to_string())?;
    let names: Vec<String> = statement
        .column_names()
        .iter()
        .map(|s| s.to_string())
        .collect();
    let values = sql_values(args)?;
    let rows = statement
        .query_map(rusqlite::params_from_iter(values), |row| {
            let mut object = serde_json::Map::new();
            for (i, name) in names.iter().enumerate() {
                let value: SqlValue = row.get(i)?;
                object.insert(
                    name.clone(),
                    match value {
                        SqlValue::Null => Value::Null,
                        SqlValue::Integer(n) => json!(n),
                        SqlValue::Real(n) => json!(n),
                        SqlValue::Text(s) => Value::String(s),
                        SqlValue::Blob(_) => Value::Null,
                    },
                );
            }
            Ok(Value::Object(object))
        })
        .map_err(|e| e.to_string())?;
    Ok(Value::Array(
        rows.collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|e| e.to_string())?,
    ))
}
fn sql_values(args: &[Value]) -> Result<Vec<SqlValue>, String> {
    args.iter()
        .map(|v| match v {
            Value::Null => Ok(SqlValue::Null),
            Value::String(s) => Ok(SqlValue::Text(s.clone())),
            Value::Number(n) => n
                .as_i64()
                .map(SqlValue::Integer)
                .ok_or("invalid integer".into()),
            _ => Err("invalid SQL value".into()),
        })
        .collect()
}
fn table(a: &Value) -> Result<&str, String> {
    let t = a["table"].as_str().ok_or("missing table")?;
    if ["projects", "workspaces", "terminals", "agents"].contains(&t) {
        Ok(t)
    } else {
        Err("invalid table".into())
    }
}
fn records(db: &Connection, t: &str, id: Option<&str>) -> Result<Value, String> {
    let rows = if let Some(id) = id {
        query(
            db,
            &format!("SELECT data FROM {t} WHERE id=?"),
            &[json!(id)],
        )?
    } else {
        query(db, &format!("SELECT data FROM {t} ORDER BY rowid"), &[])?
    };
    let values: Result<Vec<Value>, _> = rows
        .as_array()
        .unwrap()
        .iter()
        .map(|r| serde_json::from_str(r["data"].as_str().unwrap()))
        .collect();
    Ok(json!(values.map_err(|e| e.to_string())?))
}
fn put(db: &Connection, t: &str, v: &Value, notification: Option<&Value>) -> Result<(), String> {
    db.execute(
        &format!(
            "INSERT INTO {t}(id,data) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data"
        ),
        params![v["id"].as_str().ok_or("missing id")?, v.to_string()],
    )
    .map_err(|e| e.to_string())?;
    db.execute(
        "INSERT INTO events(kind,entityId,at) VALUES(?,?,strftime('%Y-%m-%dT%H:%M:%fZ','now'))",
        params![t, v["id"].as_str()],
    )
    .map_err(|e| e.to_string())?;
    if let Some(n) = notification.filter(|n| !n.is_null()) {
        let seq = db.last_insert_rowid();
        db.execute(
            "INSERT INTO notification_events(sequence,terminalId,data) VALUES(?,?,?)",
            params![seq, n["terminalId"].as_str(), n.to_string()],
        )
        .map_err(|e| e.to_string())?;
    }
    Ok(())
}
fn delete_workspace(db: &Connection, id: &str) -> Result<(), String> {
    for sql in ["DELETE FROM notification_events WHERE terminalId IN (SELECT id FROM terminals WHERE json_extract(data,'$.workspaceId')=?)","DELETE FROM output WHERE terminalId IN (SELECT id FROM terminals WHERE json_extract(data,'$.workspaceId')=?)","DELETE FROM terminals WHERE json_extract(data,'$.workspaceId')=?","DELETE FROM agents WHERE json_extract(data,'$.workspaceId')=?","DELETE FROM workspaces WHERE id=?"]{db.execute(sql,[id]).map_err(|e|e.to_string())?;}
    db.execute("INSERT INTO events(kind,entityId,at) VALUES('workspaces',?,strftime('%Y-%m-%dT%H:%M:%fZ','now'))",[id]).map_err(|e|e.to_string())?;
    Ok(())
}
fn handle(db: &mut Connection, r: &Request) -> Result<Value, String> {
    let a = &r.args;
    match r.op.as_str() {
        "barrier" => Ok(json!({})),
        "list" => records(db, table(a)?, None),
        "get" => Ok(records(db, table(a)?, a["id"].as_str())?
            .as_array()
            .unwrap()
            .first()
            .cloned()
            .unwrap_or(Value::Null)),
        "state" => Ok(
            json!({"protocolVersion":1,"hostName":a["hostName"],"revision":query(db,"SELECT COALESCE(MAX(sequence),0) AS n FROM events",&[])?[0]["n"],"projects":records(db,"projects",None)?,"workspaces":records(db,"workspaces",None)?,"terminals":records(db,"terminals",None)?}),
        ),
        "put" => {
            let tx = db.transaction().map_err(|e| e.to_string())?;
            put(&tx, table(a)?, &a["value"], a.get("notification"))?;
            tx.commit().map_err(|e| e.to_string())?;
            Ok(Value::Null)
        }
        "compare_put" => {
            let t = table(a)?;
            let id = a["id"].as_str().ok_or("missing id")?;
            if a["value"]["id"].as_str() != Some(id) {
                return Err("id mismatch".into());
            }
            let expected = a.get("expected").ok_or("missing expected")?;
            let tx = db.transaction().map_err(|e| e.to_string())?;
            let current = records(&tx, t, Some(id))?
                .as_array()
                .unwrap()
                .first()
                .cloned()
                .unwrap_or(Value::Null);
            if &current != expected {
                return Ok(json!(false));
            }
            put(&tx, t, &a["value"], a.get("notification"))?;
            tx.commit().map_err(|e| e.to_string())?;
            Ok(json!(true))
        }
        "put_pair" => {
            let tx = db.transaction().map_err(|e| e.to_string())?;
            put(&tx, "projects", &a["project"], None)?;
            put(&tx, "workspaces", &a["workspace"], None)?;
            tx.commit().map_err(|e| e.to_string())?;
            Ok(Value::Null)
        }
        "delete_workspace" => {
            let tx = db.transaction().map_err(|e| e.to_string())?;
            delete_workspace(&tx, a["id"].as_str().ok_or("id")?)?;
            tx.commit().map_err(|e| e.to_string())?;
            Ok(Value::Null)
        }
        "remove_project" => {
            let tx = db.transaction().map_err(|e| e.to_string())?;
            let id = a["id"].as_str().ok_or("id")?;
            let workspaces = query(
                &tx,
                "SELECT id FROM workspaces WHERE json_extract(data,'$.projectId')=?",
                &[json!(id)],
            )?;
            for w in workspaces.as_array().unwrap() {
                delete_workspace(&tx, w["id"].as_str().unwrap())?;
            }
            tx.execute("DELETE FROM projects WHERE id=?", [id])
                .map_err(|e| e.to_string())?;
            tx.execute("INSERT INTO events(kind,entityId,at) VALUES('projects',?,strftime('%Y-%m-%dT%H:%M:%fZ','now'))",[id]).map_err(|e|e.to_string())?;
            tx.commit().map_err(|e| e.to_string())?;
            Ok(Value::Null)
        }
        "recover" => {
            let tx = db.transaction().map_err(|e| e.to_string())?;
            let terminals = records(&tx, "terminals", None)?;
            for row in terminals.as_array().unwrap() {
                if row["status"] == "running" {
                    let mut value = row.clone();
                    value["status"] = json!("interrupted");
                    put(&tx, "terminals", &value, None)?;
                }
            }
            tx.commit().map_err(|e| e.to_string())?;
            Ok(Value::Null)
        }
        "notifications" => {
            let rows=query(db,"SELECT sequence,data FROM notification_events WHERE sequence>? ORDER BY sequence LIMIT 256",&[a["after"].clone()])?;
            let mut events = Vec::new();
            let mut cursor = a["after"].clone();
            for r in rows.as_array().unwrap() {
                let mut v: Value =
                    serde_json::from_str(r["data"].as_str().unwrap()).map_err(|e| e.to_string())?;
                v["sequence"] = r["sequence"].clone();
                cursor = r["sequence"].clone();
                events.push(v);
            }
            Ok(json!({"more":events.len()==256,"cursor":cursor,"events":events}))
        }
        "events" => query(
            db,
            "SELECT * FROM events WHERE sequence>? ORDER BY sequence LIMIT 256",
            &[a["after"].clone()],
        ),
        "operation" => Ok(query(
            db,
            "SELECT * FROM operations WHERE id=?",
            &[a["id"].clone()],
        )?
        .as_array()
        .unwrap()
        .first()
        .cloned()
        .unwrap_or(Value::Null)),
        "operation_start" => {
            db.execute(
                "INSERT INTO operations(id,hash,status) VALUES(?,?,'pending')",
                params![a["id"].as_str(), a["hash"].as_str()],
            )
            .map_err(|e| e.to_string())?;
            Ok(Value::Null)
        }
        "operation_finish" => {
            db.execute(
                "UPDATE operations SET status=?,result=? WHERE id=?",
                params![a["status"].as_str(), a["result"].as_str(), a["id"].as_str()],
            )
            .map_err(|e| e.to_string())?;
            Ok(Value::Null)
        }
        "pty_exit" => {
            let id = a["terminalId"].as_str().ok_or("id")?;
            let row = records(db, "terminals", Some(id))?;
            if let Some(row) = row.as_array().unwrap().first() {
                let tx = db.transaction().map_err(|e| e.to_string())?;
                let mut v = row.clone();
                v["status"] = json!("exited");
                v["exitCode"] = a["exitCode"].clone();
                v.as_object_mut().unwrap().remove("activity");
                put(&tx, "terminals", &v, None)?;
                tx.commit().map_err(|e| e.to_string())?;
            }
            Ok(Value::Null)
        }
        "snapshot" => {
            let mut result = serde_json::Map::new();
            for table in ["projects", "workspaces", "terminals", "agents"] {
                let rows = query(db, &format!("SELECT data FROM {table} ORDER BY rowid"), &[])?;
                let values: Result<Vec<Value>, _> = rows
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|row| serde_json::from_str(row["data"].as_str().unwrap()))
                    .collect();
                result.insert(table.into(), json!(values.map_err(|e| e.to_string())?));
            }
            result.insert(
                "revision".into(),
                query(db, "SELECT COALESCE(MAX(sequence),0) AS n FROM events", &[])?[0]["n"]
                    .clone(),
            );
            Ok(Value::Object(result))
        }
        "transaction" => {
            let tx = db.transaction().map_err(|e| e.to_string())?;
            for item in a.as_array().ok_or("invalid transaction")? {
                let values = sql_values(item["args"].as_array().ok_or("invalid args")?)?;
                tx.execute(
                    item["sql"].as_str().ok_or("invalid sql")?,
                    rusqlite::params_from_iter(values),
                )
                .map_err(|e| e.to_string())?;
            }
            tx.commit().map_err(|e| e.to_string())?;
            Ok(json!({}))
        }
        "append" => {
            let tx = db.transaction().map_err(|e| e.to_string())?;
            {
                let mut insert = tx
                    .prepare_cached("INSERT INTO output(terminalId,data,cols,rows) VALUES(?,?,?,?)")
                    .map_err(|e| e.to_string())?;
                for row in a.as_array().ok_or("invalid output")? {
                    insert
                        .execute(params![
                            row["terminalId"].as_str(),
                            row["data"].as_str(),
                            row["cols"].as_i64(),
                            row["rows"].as_i64()
                        ])
                        .map_err(|e| e.to_string())?;
                }
            }
            tx.commit().map_err(|e| e.to_string())?;
            Ok(json!({}))
        }
        "output" => {
            let after = a["after"].as_i64().ok_or("invalid cursor")?;
            let mut stmt=db.prepare_cached("SELECT sequence,data,cols,rows FROM output WHERE terminalId=? AND sequence>? ORDER BY sequence LIMIT 256").map_err(|e|e.to_string())?;
            let mut rows = stmt
                .query(params![a["terminalId"].as_str(), after])
                .map_err(|e| e.to_string())?;
            let mut chunks = Vec::new();
            let mut bytes = 0;
            let mut more = false;
            let mut cursor = after;
            while let Some(row) = rows.next().map_err(|e| e.to_string())? {
                if bytes >= 256 * 1024 {
                    more = true;
                    break;
                }
                let data: String = row.get(1).map_err(|e| e.to_string())?;
                cursor = row.get(0).map_err(|e| e.to_string())?;
                bytes += data.len();
                chunks.push(json!({"sequence":cursor,"data":data,"cols":row.get::<_,Option<i64>>(2).map_err(|e|e.to_string())?,"rows":row.get::<_,Option<i64>>(3).map_err(|e|e.to_string())?}));
            }
            more |= chunks.len() == 256;
            let data: String = if a["chunksOnly"] == true {
                String::new()
            } else {
                chunks.iter().map(|c| c["data"].as_str().unwrap()).collect()
            };
            Ok(json!({"data":data,"chunks":chunks,"cursor":cursor,"more":more}))
        }
        "query" => query(
            db,
            a["sql"].as_str().ok_or("invalid sql")?,
            a["args"].as_array().ok_or("invalid args")?,
        ),
        _ => Err("unknown operation".into()),
    }
}

struct Job {
    request: Request,
    reply: oneshot::Sender<Result<Value, ApiError>>,
    _credit: Option<OwnedSemaphorePermit>,
}
// Only these DB-only statements can share a transaction. Other handlers may
// open their own transactions or implement CAS/barrier boundaries.
fn groupable(job: &Job) -> bool {
    matches!(job.request.op.as_str(), "operation_start" | "operation_finish")
}
const CONTROL_QUANTUM: usize = 8;
fn ready_group(first: Job, rx: &mut mpsc::Receiver<Job>, pending: &mut Option<Job>, limit: usize) -> Vec<Job> {
    let mut jobs = vec![first];
    if !groupable(&jobs[0]) { return jobs; }
    while jobs.len() < limit {
        match rx.try_recv() {
            Ok(job) if groupable(&job) => jobs.push(job),
            Ok(job) => { *pending = Some(job); break; }
            Err(_) => break,
        }
    }
    jobs
}
fn complete(job: Job, result: Result<Value, ApiError>, changes: &broadcast::Sender<Change>) {
    if result.is_ok() && (job.request.op != "compare_put" || result.as_ref().ok() == Some(&Value::Bool(true))) {
        if let Some(change) = change(&job.request) { let _ = changes.send(change); }
    }
    let _ = job.reply.send(result);
}
// Returns false only if rollback could not restore autocommit. The writer then
// closes its queues rather than processing further jobs in an uncertain tx.
fn execute_group(db: &mut Connection, jobs: Vec<Job>, changes: &broadcast::Sender<Change>) -> bool {
    if jobs.len() == 1 {
        let job = jobs.into_iter().next().unwrap();
        let result = handle(db, &job.request).map_err(|_| ApiError::storage());
        complete(job, result, changes);
        return db.is_autocommit();
    }
    debug_assert!(jobs.iter().all(groupable));
    if db.execute_batch("BEGIN IMMEDIATE").is_err() {
        for job in jobs { complete(job, Err(ApiError::storage()), changes); }
        return db.is_autocommit();
    }
    let results: Result<Vec<Value>, String> = jobs.iter().map(|job| handle(db, &job.request)).collect();
    match results {
        Ok(results) => {
            // Never replay a failed COMMIT: its durability outcome may be unknown.
            // No successful reply or event is published before the FULL commit.
            let committed = db.execute_batch("COMMIT").is_ok();
            if !committed && !db.is_autocommit() { let _ = db.execute_batch("ROLLBACK"); }
            for (job, result) in jobs.into_iter().zip(results) {
                complete(job, if committed { Ok(result) } else { Err(ApiError::storage()) }, changes);
            }
        }
        Err(_) => {
            // A duplicate/invalid statement must not fail unrelated accepted
            // jobs. Retry FIFO individually only after confirmed full rollback.
            if db.execute_batch("ROLLBACK").is_ok() {
                for job in jobs {
                    let result = handle(db, &job.request).map_err(|_| ApiError::storage());
                    complete(job, result, changes);
                    if !db.is_autocommit() { return false; }
                }
            } else {
                for job in jobs { complete(job, Err(ApiError::storage()), changes); }
            }
        }
    }
    db.is_autocommit()
}
#[derive(Clone)]
pub struct StoreHandle {
    events:broadcast::Sender<Change>,
    writes: mpsc::Sender<Job>,
    bulk: mpsc::Sender<Job>,
    reads: mpsc::Sender<Job>,
    credit: Arc<Semaphore>,
    bulk_credit: Arc<Semaphore>,
    enqueue: Arc<tokio::sync::RwLock<()>>,
}
impl StoreHandle {
    pub async fn open(path: &Path, events: broadcast::Sender<Change>) -> Result<Self, ApiError> {
        let path = path.to_owned();
        let (writes, mut rx) = mpsc::channel::<Job>(64);
        let (bulk, mut bulk_rx) = mpsc::channel::<Job>(128);
        let (reads, mut read_rx) = mpsc::channel::<Job>(16);
        let (ready, ready_rx) = oneshot::channel();
        let changes=events.clone();
        std::thread::Builder::new().name("native-store".into()).spawn(move||{
   let init=(||->Result<(Connection,Connection),String>{let writer=Connection::open(&path).map_err(|e|e.to_string())?;writer.execute_batch(SCHEMA).map_err(|e|e.to_string())?;let columns:Vec<String>=writer.prepare("PRAGMA table_info(output)").map_err(|e|e.to_string())?.query_map([],|r|r.get(1)).map_err(|e|e.to_string())?.collect::<rusqlite::Result<_>>().map_err(|e|e.to_string())?;if !columns.iter().any(|c|c=="cols"){writer.execute_batch("ALTER TABLE output ADD COLUMN cols INTEGER; ALTER TABLE output ADD COLUMN rows INTEGER;").map_err(|e|e.to_string())?;}let reader=Connection::open(&path).map_err(|e|e.to_string())?;reader.execute_batch("PRAGMA query_only=ON;PRAGMA busy_timeout=5000;").map_err(|e|e.to_string())?;Ok((writer,reader))})();
   let Ok((mut writer,mut reader))=init else {let _=ready.send(false);return;};
   std::thread::Builder::new().name("native-output-read".into()).spawn(move||{while let Some(job)=read_rx.blocking_recv(){let result=handle(&mut reader,&job.request).map_err(|_|ApiError::storage());let _=job.reply.send(result);}}).ok();
   let _=ready.send(true);
   let runtime=tokio::runtime::Builder::new_current_thread().build().expect("store executor");
   runtime.block_on(async {
    let mut control_run=0;
    let mut pending=None;
    loop {
     // A busy control lane gets at most eight consecutive jobs while bulk is ready.
     let job=if control_run>=CONTROL_QUANTUM {control_run=0;match bulk_rx.try_recv(){Ok(job)=>Some((job,false)),Err(_)=>None}}else{None};
     let next=if let Some(job)=job {Some(job)}else if let Some(job)=pending.take(){Some((job,true))}else{tokio::select!{biased;
      job=rx.recv(),if !rx.is_closed()||!rx.is_empty()=>job.map(|j|(j,true)),
      job=bulk_rx.recv(),if !bulk_rx.is_closed()||!bulk_rx.is_empty()=>job.map(|j|(j,false)),
      else=>break,
     }};
     let Some((job,control))=next else{continue;};
     let jobs=if control {ready_group(job,&mut rx,&mut pending,CONTROL_QUANTUM-control_run)}else{vec![job]};
     control_run=if control{control_run+jobs.len()}else{0};
     if !execute_group(&mut writer,jobs,&changes){break;}
    }
   });
  }).map_err(|_|ApiError::storage())?;
        if !ready_rx.await.unwrap_or(false) {
            return Err(ApiError::storage());
        }
        let store = Self {
            events,
            writes,
            bulk,
            reads,
            credit: Arc::new(Semaphore::new(4 * 1024 * 1024)),
            bulk_credit: Arc::new(Semaphore::new(12 * 1024 * 1024)),
            enqueue: Arc::new(tokio::sync::RwLock::new(())),
        };
        store.call("recover", json!({})).await?;
        Ok(store)
    }
    pub fn signal_change(&self,change:Change){let _=self.events.send(change);}
    pub async fn call(&self, op: &str, args: Value) -> Result<Value, ApiError> {
        if op == "barrier" {
            // Exclude new enqueues while FIFO fences pass through both lanes. Jobs already
            // awaiting credits are not accepted yet and therefore fall after this barrier.
            let _gate = self.enqueue.write().await;
            for tx in [&self.bulk, &self.writes] {
                let (reply, rx) = oneshot::channel();
                tx.send(Job {
                    request: Request {
                        op: "barrier".into(),
                        args: Value::Null,
                    },
                    reply,
                    _credit: None,
                })
                .await
                .map_err(|_| ApiError::storage())?;
                rx.await.map_err(|_| ApiError::storage())??;
            }
            return Ok(json!({}));
        }
        let bytes = serde_json::to_vec(&args)
            .map_err(|_| ApiError::storage())?
            .len()
            .max(1);
        if bytes > 4 * 1024 * 1024 {
            return Err(ApiError::new(
                "payload_too_large",
                "保存要求が大きすぎます。",
                413,
            ));
        }
        let bulk = op == "append" || op == "pty_exit";
        let credit = if bulk {
            &self.bulk_credit
        } else {
            &self.credit
        };
        let credit = credit
            .clone()
            .acquire_many_owned(bytes as u32)
            .await
            .map_err(|_| ApiError::storage())?;
        let (reply, rx) = oneshot::channel();
        let job = Job {
            request: Request {
                op: op.into(),
                args,
            },
            reply,
            _credit: Some(credit),
        };
        let tx = if op == "output" {
            &self.reads
        } else if bulk {
            &self.bulk
        } else {
            &self.writes
        };
        {
            let _gate = self.enqueue.read().await;
            tx.send(job).await.map_err(|_| ApiError::storage())?;
        }
        rx.await.map_err(|_| ApiError::storage())?
    }

    pub async fn get(&self, table: &str, id: &str) -> Result<Option<Value>, ApiError> {
        let v = self.call("get", json!({"table":table,"id":id})).await?;
        Ok(if v.is_null() { None } else { Some(v) })
    }
    pub async fn list(&self, table: &str) -> Result<Vec<Value>, ApiError> {
        Ok(self
            .call("list", json!({"table":table}))
            .await?
            .as_array()
            .cloned()
            .unwrap_or_default())
    }
    /// Reapply a field update to the latest row after a conflicting native owner write.
    pub async fn update<F>(
        &self,
        table: &str,
        id: &str,
        mutate: F,
    ) -> Result<Option<Value>, ApiError>
    where
        F: Fn(&mut Value) + Send + Sync,
    {
        loop {
            let Some(expected) = self.get(table, id).await? else {
                return Ok(None);
            };
            let mut value = expected.clone();
            mutate(&mut value);
            if value == expected {
                return Ok(Some(value));
            }
            if self
                .call(
                    "compare_put",
                    json!({"table":table,"id":id,"expected":expected,"value":value}),
                )
                .await?
                == true
            {
                return Ok(Some(value));
            }
        }
    }
    pub async fn put(
        &self,
        table: &str,
        value: Value,
        notification: Option<Value>,
    ) -> Result<(), ApiError> {
        self.call(
            "put",
            json!({"table":table,"value":value,"notification":notification}),
        )
        .await?;
        Ok(())
    }
}
fn change(r: &Request) -> Option<Change> {
    let a = &r.args;
    match r.op.as_str() {
        "put" | "compare_put" => Some(Change {
            state: true,
            terminals: if a["table"] == "terminals" {
                vec![a["value"]["id"].as_str()?.to_owned()]
            } else {
                vec![]
            },
            agent_terminals: if a["table"] == "agents" {
                a["value"]["terminalId"]
                    .as_str()
                    .map(|s| vec![s.to_owned()])
                    .unwrap_or_default()
            } else {
                vec![]
            },
            browser: false,
        }),
        "append" => Some(Change {
            state: false,
            terminals: a
                .as_array()?
                .iter()
                .filter_map(|r| r["terminalId"].as_str().map(String::from))
                .collect(),
            agent_terminals: vec![],
            browser: false,
        }),
        "pty_exit" => Some(Change {
            state: true,
            terminals: vec![a["terminalId"].as_str()?.to_owned()],
            agent_terminals: vec![],
            browser: false,
        }),
        "put_pair" | "delete_workspace" | "remove_project" => Some(Change {
            state: true,
            ..Default::default()
        }),
        _ => None,
    }
}

#[cfg(test)]
mod cas_tests {
    use super::*;
    #[test]
    fn compare_put_preserves_newer_edits_and_identity() {
        let mut db = Connection::open_in_memory().unwrap();
        db.execute_batch(SCHEMA).unwrap();
        let old = json!({"id":"w","title":"old"});
        handle(
            &mut db,
            &Request {
                op: "put".into(),
                args: json!({"table":"workspaces","value":old}),
            },
        )
        .unwrap();
        let args = json!({"table":"workspaces","id":"w","expected":old,"value":{"id":"w","title":"manual"}});
        assert_eq!(
            handle(
                &mut db,
                &Request {
                    op: "compare_put".into(),
                    args: args.clone()
                }
            )
            .unwrap(),
            true
        );
        let revision = query(&db, "SELECT MAX(sequence) AS n FROM events", &[]).unwrap();
        assert_eq!(
            handle(
                &mut db,
                &Request {
                    op: "compare_put".into(),
                    args
                }
            )
            .unwrap(),
            false
        );
        assert_eq!(
            query(&db, "SELECT MAX(sequence) AS n FROM events", &[]).unwrap(),
            revision
        );
        assert_eq!(
            records(&db, "workspaces", Some("w")).unwrap()[0]["title"],
            "manual"
        );
        assert!(handle(
            &mut db,
            &Request {
                op: "compare_put".into(),
                args: json!({"table":"workspaces","id":"w","expected":null,"value":{"id":"other"}})
            }
        )
        .is_err());
    }
}

#[cfg(test)]
mod lane_tests {
    use super::*;
    #[tokio::test]
    async fn bulk_credit_pressure_does_not_block_control_or_barrier() {
        let dir = std::env::temp_dir().join(format!("neura-store-lanes-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&dir).unwrap();
        let (events, _) = broadcast::channel(8);
        let store = StoreHandle::open(&dir.join("test.sqlite"), events)
            .await
            .unwrap();
        // Exhaust only bulk credits, exactly as queued output can do under pressure.
        let pressure = store
            .bulk_credit
            .clone()
            .acquire_many_owned(12 * 1024 * 1024)
            .await
            .unwrap();
        let producer = store.clone();
        let pending = tokio::spawn(async move {
            producer
                .call("append", json!([{"terminalId":"t","data":"日本語"}]))
                .await
        });
        tokio::task::yield_now().await;
        tokio::time::timeout(
            std::time::Duration::from_secs(2),
            store.put("projects", json!({"id":"p"}), None),
        )
        .await
        .unwrap()
        .unwrap();
        tokio::time::timeout(
            std::time::Duration::from_secs(2),
            store.call("barrier", json!({})),
        )
        .await
        .unwrap()
        .unwrap();
        assert!(!pending.is_finished());
        drop(pressure);
        pending.await.unwrap().unwrap();
        store.call("barrier", json!({})).await.unwrap();
        let output = store
            .call("output", json!({"terminalId":"t","after":0}))
            .await
            .unwrap();
        assert_eq!(output["data"], "日本語");
        let chunks = store
            .call(
                "output",
                json!({"terminalId":"t","after":0,"chunksOnly":true}),
            )
            .await
            .unwrap();
        assert_eq!(chunks["data"], "");
        assert_eq!(chunks["chunks"], output["chunks"]);
        assert_eq!(chunks["cursor"], output["cursor"]);
        drop(store);
        let _ = std::fs::remove_dir_all(dir);
    }
}

#[cfg(test)]
mod update_race_tests {
    use super::*;
    #[tokio::test]
    async fn stale_resize_and_launch_failure_preserve_exit_and_provider_fields() {
        let dir = std::env::temp_dir().join(format!("neura-store-race-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&dir).unwrap();
        let (events, _) = broadcast::channel(8);
        let store = StoreHandle::open(&dir.join("test.sqlite"), events)
            .await
            .unwrap();
        store
            .put(
                "terminals",
                json!({"id":"t","status":"running","cols":80,"rows":24}),
                None,
            )
            .await
            .unwrap();
        let stale = store.get("terminals", "t").await.unwrap().unwrap();
        let barrier = Arc::new(tokio::sync::Barrier::new(2));
        let b = barrier.clone();
        let writer = store.clone();
        let provider = tokio::spawn(async move {
            writer
                .update("terminals", "t", |v| {
                    v["status"] = json!("exited");
                    v["activity"] = json!("idle");
                    v["sessionName"] = json!("latest");
                })
                .await
                .unwrap();
            b.wait().await;
        });
        barrier.wait().await;
        provider.await.unwrap();
        let mut stale_resize = stale.clone();
        stale_resize["cols"] = json!(100);
        assert_eq!(
            store
                .call(
                    "compare_put",
                    json!({"table":"terminals","id":"t","expected":stale,"value":stale_resize})
                )
                .await
                .unwrap(),
            false
        );
        store
            .update("terminals", "t", |v| {
                v["cols"] = json!(100);
                v["rows"] = json!(30);
            })
            .await
            .unwrap();
        store
            .update("terminals", "t", |v| {
                if v["status"] == "running" {
                    v["status"] = json!("interrupted");
                }
            })
            .await
            .unwrap();
        let current = store.get("terminals", "t").await.unwrap().unwrap();
        assert_eq!(current["status"], "exited");
        assert_eq!(current["sessionName"], "latest");
        assert_eq!(current["activity"], "idle");
        assert_eq!(current["cols"], 100);
        store
            .put(
                "projects",
                json!({"id":"p","isGit":false,"name":"original"}),
                None,
            )
            .await
            .unwrap();
        let writer = store.clone();
        let rename = tokio::spawn(async move {
            writer
                .update("projects", "p", |v| {
                    v["name"] = json!("manual");
                    v["worktreeStartup"] = json!(["claude"]);
                })
                .await
                .unwrap();
        });
        let writer = store.clone();
        let promote = tokio::spawn(async move {
            writer
                .update("projects", "p", |v| v["isGit"] = json!(true))
                .await
                .unwrap();
        });
        rename.await.unwrap();
        promote.await.unwrap();
        let current = store.get("projects", "p").await.unwrap().unwrap();
        assert_eq!(current["name"], "manual");
        assert_eq!(current["isGit"], true);
        assert_eq!(current["worktreeStartup"], json!(["claude"]));
        drop(store);
        let _ = std::fs::remove_dir_all(dir);
    }
}

#[cfg(test)]
mod operation_group_tests {
    use super::*;
    fn job(op: &str, args: Value) -> (Job, oneshot::Receiver<Result<Value, ApiError>>) {
        let (reply, rx) = oneshot::channel();
        (Job { request: Request { op: op.into(), args }, reply, _credit: None }, rx)
    }
    fn start(id: &str) -> (Job, oneshot::Receiver<Result<Value, ApiError>>) {
        job("operation_start", json!({"id":id,"hash":"h"}))
    }
    fn db() -> Connection {
        let mut db = Connection::open_in_memory().unwrap();
        db.execute_batch(SCHEMA).unwrap();
        // Keep the same handle API exercised by the real writer.
        handle(&mut db, &Request { op:"barrier".into(), args:Value::Null }).unwrap();
        db
    }
    #[test]
    fn duplicate_rolls_back_then_replays_db_only_jobs_in_order() {
        let mut db = db();
        let (events, mut changes) = broadcast::channel(8);
        let (a, mut ar) = start("a");
        let (duplicate, mut dr) = start("a");
        let (b, mut br) = start("b");
        let (finish, mut fr) = job("operation_finish", json!({"id":"b","status":"done","result":"{}"}));
        assert!(execute_group(&mut db, vec![a, duplicate, b, finish], &events));
        assert!(ar.try_recv().unwrap().is_ok());
        assert!(dr.try_recv().unwrap().is_err());
        assert!(br.try_recv().unwrap().is_ok());
        assert!(fr.try_recv().unwrap().is_ok());
        assert_eq!(query(&db,"SELECT id,status FROM operations ORDER BY id",&[]).unwrap(),
            json!([{"id":"a","status":"pending"},{"id":"b","status":"done"}]));
        assert!(changes.try_recv().is_err());
        assert!(db.is_autocommit());
    }
    #[test]
    fn failed_commit_never_publishes_success_or_replays_pending_operation() {
        let mut db = db();
        db.execute_batch("PRAGMA foreign_keys=ON;
            CREATE TABLE parent(id INTEGER PRIMARY KEY);
            CREATE TABLE deferred_child(id INTEGER REFERENCES parent(id) DEFERRABLE INITIALLY DEFERRED);
            CREATE TRIGGER fail_commit AFTER UPDATE ON operations BEGIN INSERT INTO deferred_child VALUES(123); END;").unwrap();
        let (events, mut changes) = broadcast::channel(8);
        let (a, mut ar) = start("a");
        let (finish, mut fr) = job("operation_finish", json!({"id":"a","status":"done","result":"{}"}));
        assert!(execute_group(&mut db, vec![a, finish], &events));
        assert!(ar.try_recv().unwrap().is_err());
        assert!(fr.try_recv().unwrap().is_err());
        assert_eq!(query(&db,"SELECT * FROM operations",&[]).unwrap(),json!([]));
        assert_eq!(query(&db,"SELECT * FROM deferred_child",&[]).unwrap(),json!([]));
        assert!(changes.try_recv().is_err());
        assert!(db.is_autocommit());
    }
    #[test]
    fn grouping_stops_at_barrier_cas_and_nonready_job_without_waiting() {
        for boundary in ["barrier", "compare_put", "put", "operation", "query"] {
            let (tx, mut rx) = mpsc::channel(16);
            let mut pending = None;
            tx.try_send(job(boundary,Value::Null).0).unwrap();
            tx.try_send(start("later").0).unwrap();
            let group = ready_group(start("first").0,&mut rx,&mut pending,8);
            assert_eq!(group.len(),1);
            assert_eq!(pending.take().unwrap().request.op,boundary);
            assert_eq!(rx.try_recv().unwrap().request.args["id"],"later");
        }
        let (_tx, mut rx) = mpsc::channel(16);
        assert_eq!(ready_group(start("alone").0,&mut rx,&mut None,8).len(),1);
    }
    #[test]
    fn grouped_full_wal_commits_reduce_frames_and_survive_reopen() {
        let dir = std::env::temp_dir().join(format!("neura-operation-wal-{}",uuid::Uuid::new_v4()));
        std::fs::create_dir(&dir).unwrap();
        let mut frames = Vec::new();
        for grouped in [false,true] {
            let path=dir.join(if grouped {"grouped.sqlite"} else {"single.sqlite"});
            let mut db=Connection::open(&path).unwrap();
            db.execute_batch(SCHEMA).unwrap();
            db.execute_batch("PRAGMA wal_checkpoint(TRUNCATE)").unwrap();
            assert_eq!(db.query_row("PRAGMA synchronous",[],|r|r.get::<_,i64>(0)).unwrap(),2);
            assert_eq!(db.query_row("PRAGMA journal_mode",[],|r|r.get::<_,String>(0)).unwrap(),"wal");
            let (events,_) = broadcast::channel(8);
            for chunk in 0..4 {
                let mut jobs=Vec::new();let mut replies=Vec::new();
                for i in 0..8 {let(j,r)=start(&format!("{chunk}-{i}"));jobs.push(j);replies.push(r);}
                if grouped {assert!(execute_group(&mut db,jobs,&events));}
                else {for j in jobs {assert!(execute_group(&mut db,vec![j],&events));}}
                for mut r in replies {assert!(r.try_recv().unwrap().is_ok());}
            }
            let n:i64=db.query_row("PRAGMA wal_checkpoint(PASSIVE)",[],|r|r.get(1)).unwrap();
            frames.push(n);
            drop(db);
            let db=Connection::open(path).unwrap();
            assert_eq!(db.query_row("SELECT COUNT(*) FROM operations WHERE status='pending'",[],|r|r.get::<_,i64>(0)).unwrap(),32);
        }
        assert!(frames[1]*2<frames[0],"{frames:?}");
        eprintln!("32 FULL/WAL operation_start: standalone frames={}, grouped frames={}",frames[0],frames[1]);
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[tokio::test]
    async fn bulk_fence_observes_at_most_eight_control_jobs_and_cancelled_reply_still_persists() {
        let dir=std::env::temp_dir().join(format!("neura-operation-fair-{}",uuid::Uuid::new_v4()));
        std::fs::create_dir(&dir).unwrap();
        let path=dir.join("db");
        let (events,_) = broadcast::channel(8);
        let store=StoreHandle::open(&path,events).await.unwrap();
        let blocker=Connection::open(&path).unwrap();
        blocker.execute_batch("BEGIN IMMEDIATE").unwrap();
        let mut replies=Vec::new();
        for i in 0..32 {let(j,r)=start(&i.to_string());store.writes.send(j).await.unwrap();replies.push(r);}
        let (bulk, result)=job("query",json!({"sql":"SELECT COUNT(*) AS n FROM operations","args":[]}));
        store.bulk.send(bulk).await.unwrap();
        // Cancel one caller after acceptance: its pending operation is durable,
        // not removed or resent because no successful reply was observed.
        drop(replies.remove(0));
        blocker.execute_batch("ROLLBACK").unwrap();
        let n=result.await.unwrap().unwrap()[0]["n"].as_i64().unwrap();
        assert!(n<=8,"bulk waited behind {n} control jobs");
        store.call("barrier",json!({})).await.unwrap();
        for r in replies {assert!(r.await.unwrap().is_ok());}
        let row=store.call("operation",json!({"id":"0"})).await.unwrap();
        assert_eq!(row["status"],"pending");
        assert_eq!(store.call("query",json!({"sql":"SELECT COUNT(*) AS n FROM operations","args":[]})).await.unwrap()[0]["n"],32);
    }
}
