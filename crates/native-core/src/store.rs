mod deletions;
use crate::performance;
use crate::{error::ApiError, events::Change};
use rusqlite::{params, types::Value as SqlValue, Connection};
use serde::Serialize;
use serde_json::{json, Value};
use std::{path::Path, sync::Arc};
use tokio::sync::{broadcast, mpsc, oneshot, OwnedSemaphorePermit, Semaphore};
const SCHEMA: &str = "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA busy_timeout=5000;
CREATE TABLE IF NOT EXISTS agents(id TEXT PRIMARY KEY,data TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS projects(id TEXT PRIMARY KEY,data TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS workspaces(id TEXT PRIMARY KEY,data TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS terminals(id TEXT PRIMARY KEY,data TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS workspace_deletions(id TEXT PRIMARY KEY,workspace_id TEXT NOT NULL,status TEXT NOT NULL,blocks INTEGER NOT NULL,public TEXT NOT NULL,data TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS workspace_deletion_workspace ON workspace_deletions(workspace_id);
CREATE INDEX IF NOT EXISTS workspace_deletion_gate ON workspace_deletions(workspace_id,blocks);
CREATE INDEX IF NOT EXISTS workspace_deletion_status ON workspace_deletions(status);
CREATE TABLE IF NOT EXISTS operations(id TEXT PRIMARY KEY,hash TEXT NOT NULL,status TEXT NOT NULL,result TEXT);
CREATE TABLE IF NOT EXISTS events(sequence INTEGER PRIMARY KEY AUTOINCREMENT,kind TEXT NOT NULL,entityId TEXT NOT NULL,at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS notification_events(sequence INTEGER PRIMARY KEY,terminalId TEXT NOT NULL,data TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS notification_terminal ON notification_events(terminalId);
CREATE TABLE IF NOT EXISTS output(sequence INTEGER PRIMARY KEY AUTOINCREMENT,terminalId TEXT NOT NULL,data TEXT NOT NULL,cols INTEGER,rows INTEGER);
CREATE INDEX IF NOT EXISTS output_terminal ON output(terminalId,sequence);";
/// One PTY output record. Terminal bytes reach the writer as owned strings and
/// are bound to SQLite directly; they are never re-encoded as a JSON tree.
pub struct OutputRow {
    pub terminal_id: String,
    pub data: String,
    /// A resize marker (cols, rows) ordered with the surrounding output.
    pub size: Option<(u16, u16)>,
}
struct Request {
    op: String,
    args: Value,
    rows: Vec<OutputRow>,
}
impl Request {
    fn new(op: &str, args: Value) -> Self {
        Self { op: op.into(), args, rows: Vec::new() }
    }
}
/// Counts serialized bytes for queue credits without allocating the encoding.
struct ByteCount(usize);
impl std::io::Write for ByteCount {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.0 += bytes.len();
        Ok(bytes.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
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
    let mut statement = db
        .prepare_cached(&if id.is_some() {
            format!("SELECT data FROM {t} WHERE id=?")
        } else {
            format!("SELECT data FROM {t} ORDER BY rowid")
        })
        .map_err(|e| e.to_string())?;
    let mut rows = match id {
        Some(id) => statement.query([id]),
        None => statement.query([]),
    }
    .map_err(|e| e.to_string())?;
    let mut values: Vec<Value> = Vec::new();
    while let Some(row) = rows.next().map_err(|e| e.to_string())? {
        let text = row.get_ref(0).and_then(|v| v.as_str().map_err(Into::into)).map_err(|e| e.to_string())?;
        values.push(serde_json::from_str(text).map_err(|e| e.to_string())?);
    }
    if t == "workspaces" { deletions::overlay(db, &mut values)?; }
    Ok(json!(values))
}
fn put(db: &Connection, t: &str, v: &Value, notification: Option<&Value>) -> Result<(), String> {
    let mut clean;
    let v = if t == "workspaces" { clean=v.clone();if let Some(row)=clean.as_object_mut(){row.remove("deletion");}&clean } else {v};
    db.prepare_cached(&format!(
        "INSERT INTO {t}(id,data) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data"
    ))
    .and_then(|mut q| q.execute(params![v["id"].as_str().ok_or(rusqlite::Error::InvalidQuery)?, v.to_string()]))
    .map_err(|e| e.to_string())?;
    db.prepare_cached(
        "INSERT INTO events(kind,entityId,at) VALUES(?,?,strftime('%Y-%m-%dT%H:%M:%fZ','now'))",
    )
    .and_then(|mut q| q.execute(params![t, v["id"].as_str()]))
    .map_err(|e| e.to_string())?;
    if let Some(n) = notification.filter(|n| !n.is_null()) {
        let seq = db.last_insert_rowid();
        db.prepare_cached("INSERT INTO notification_events(sequence,terminalId,data) VALUES(?,?,?)")
            .and_then(|mut q| q.execute(params![seq, n["terminalId"].as_str(), n.to_string()]))
            .map_err(|e| e.to_string())?;
    }
    Ok(())
}
fn delete_workspace(db: &Connection, id: &str) -> Result<(), String> {
    for sql in ["DELETE FROM notification_events WHERE terminalId IN (SELECT id FROM terminals WHERE json_extract(data,'$.workspaceId')=?)","DELETE FROM output WHERE terminalId IN (SELECT id FROM terminals WHERE json_extract(data,'$.workspaceId')=?)","DELETE FROM terminals WHERE json_extract(data,'$.workspaceId')=?","DELETE FROM agents WHERE json_extract(data,'$.workspaceId')=?","DELETE FROM workspaces WHERE id=?"]{db.execute(sql,[id]).map_err(|e|e.to_string())?;}
    db.execute("INSERT INTO events(kind,entityId,at) VALUES('workspaces',?,strftime('%Y-%m-%dT%H:%M:%fZ','now'))",[id]).map_err(|e|e.to_string())?;
    Ok(())
}
#[cfg(test)]
static TEST_COMMIT_GATE: (std::sync::Mutex<bool>, std::sync::Condvar) = (std::sync::Mutex::new(false), std::sync::Condvar::new());
/// Statements that never write. The writer serves them in FIFO order when asked;
/// the read-only connections serve them from one WAL snapshot per request.
fn read(db: &Connection, r: &Request) -> Option<Result<Value, String>> {
    let a = &r.args;
    Some(match r.op.as_str() {
        "list" => table(a).and_then(|t| records(db, t, None)),
        "get" => table(a).and_then(|t| records(db, t, a["id"].as_str())).map(|mut rows| {
            rows.as_array_mut().and_then(|v| v.pop()).unwrap_or(Value::Null)
        }),
        "state" => (|| {
            Ok(json!({"protocolVersion":1,"hostName":a["hostName"],"revision":revision(db)?,"projects":records(db,"projects",None)?,"workspaces":records(db,"workspaces",None)?,"terminals":records(db,"terminals",None)?}))
        })(),
        "state_json" => state_json(db, a).map(Value::String),
        "notifications" => (|| {
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
        })(),
        "events" => query(
            db,
            "SELECT * FROM events WHERE sequence>? ORDER BY sequence LIMIT 256",
            &[a["after"].clone()],
        ),
        "output" => output(db, a),
        "output_page" => output_page(db, a),
        _ => return None,
    })
}
fn revision(db: &Connection) -> Result<i64, String> {
    db.prepare_cached("SELECT COALESCE(MAX(sequence),0) FROM events")
        .and_then(|mut q| q.query_row([], |r| r.get(0)))
        .map_err(|e| e.to_string())
}
/// Appends the stored rows of one table as a JSON array without building a
/// value tree. Each row is still validated so corrupt data fails closed.
fn raw_rows(db: &Connection, t: &str, out: &mut String) -> Result<(), String> {
    let mut statement = db
        .prepare_cached(&format!("SELECT data FROM {t} ORDER BY rowid"))
        .map_err(|e| e.to_string())?;
    let mut rows = statement.query([]).map_err(|e| e.to_string())?;
    out.push('[');
    let mut first = true;
    while let Some(row) = rows.next().map_err(|e| e.to_string())? {
        let text = row.get_ref(0).and_then(|v| v.as_str().map_err(Into::into)).map_err(|e| e.to_string())?;
        serde_json::from_str::<serde::de::IgnoredAny>(text).map_err(|e| e.to_string())?;
        if !first {
            out.push(',');
        }
        first = false;
        out.push_str(text);
    }
    out.push(']');
    Ok(())
}
/// The `state` object as JSON text with its closing brace omitted, so the HTTP
/// layer can append process-level members. Same members and order as `state`.
fn state_json(db: &Connection, a: &Value) -> Result<String, String> {
    let mut out = String::with_capacity(8 * 1024);
    out.push_str("{\"protocolVersion\":1,\"hostName\":");
    out.push_str(&a["hostName"].to_string());
    out.push_str(",\"revision\":");
    out.push_str(&revision(db)?.to_string());
    out.push_str(",\"projects\":");
    raw_rows(db, "projects", &mut out)?;
    out.push_str(",\"workspaces\":");
    let overlaid: bool = db
        .prepare_cached("SELECT EXISTS(SELECT 1 FROM workspace_deletions)")
        .and_then(|mut q| q.query_row([], |r| r.get(0)))
        .map_err(|e| e.to_string())?;
    if overlaid {
        out.push_str(&records(db, "workspaces", None)?.to_string());
    } else {
        raw_rows(db, "workspaces", &mut out)?;
    }
    out.push_str(",\"terminals\":");
    raw_rows(db, "terminals", &mut out)?;
    Ok(out)
}
const OUTPUT_PAGE: &str = "SELECT sequence,data,cols,rows FROM output WHERE terminalId=? AND sequence>? ORDER BY sequence LIMIT 256";
fn output(db: &Connection, a: &Value) -> Result<Value, String> {
    let after = a["after"].as_i64().ok_or("invalid cursor")?;
    let mut stmt = db.prepare_cached(OUTPUT_PAGE).map_err(|e| e.to_string())?;
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
#[derive(Serialize)]
struct Chunk<'a> {
    sequence: i64,
    data: &'a str,
    cols: Option<i64>,
    rows: Option<i64>,
}
/// The complete `/output` response body as JSON text, or null when the terminal
/// does not exist. Same members, order and paging limits as `output` plus the
/// terminal's status/cols/rows. Terminal bytes go from SQLite straight into the
/// encoder. The terminal row is read first inside the request's snapshot, so an
/// exited status is never paired with output older than that exit.
fn output_page(db: &Connection, a: &Value) -> Result<Value, String> {
    let id = a["terminalId"].as_str().ok_or("missing id")?;
    let after = a["after"].as_i64().ok_or("invalid cursor")?;
    let terminal: Value = {
        let mut statement = db
            .prepare_cached("SELECT data FROM terminals WHERE id=?")
            .map_err(|e| e.to_string())?;
        let mut rows = statement.query([id]).map_err(|e| e.to_string())?;
        let Some(row) = rows.next().map_err(|e| e.to_string())? else {
            return Ok(Value::Null);
        };
        let text = row.get_ref(0).and_then(|v| v.as_str().map_err(Into::into)).map_err(|e| e.to_string())?;
        serde_json::from_str(text).map_err(|e| e.to_string())?
    };
    let joined = a["chunksOnly"] != true;
    let mut stmt = db.prepare_cached(OUTPUT_PAGE).map_err(|e| e.to_string())?;
    let mut rows = stmt.query(params![id, after]).map_err(|e| e.to_string())?;
    let mut chunks: Vec<u8> = Vec::with_capacity(1024);
    let mut data = String::new();
    let (mut bytes, mut count, mut more, mut cursor) = (0, 0, false, after);
    while let Some(row) = rows.next().map_err(|e| e.to_string())? {
        if bytes >= 256 * 1024 {
            more = true;
            break;
        }
        let text = row.get_ref(1).and_then(|v| v.as_str().map_err(Into::into)).map_err(|e| e.to_string())?;
        cursor = row.get(0).map_err(|e| e.to_string())?;
        bytes += text.len();
        if joined {
            data.push_str(text);
        }
        chunks.push(if count == 0 { b'[' } else { b',' });
        count += 1;
        serde_json::to_writer(
            &mut chunks,
            &Chunk {
                sequence: cursor,
                data: text,
                cols: row.get(2).map_err(|e| e.to_string())?,
                rows: row.get(3).map_err(|e| e.to_string())?,
            },
        )
        .map_err(|e| e.to_string())?;
    }
    more |= count == 256;
    let mut out: Vec<u8> = Vec::with_capacity(chunks.len() + data.len() + 160);
    out.extend_from_slice(b"{\"data\":");
    serde_json::to_writer(&mut out, &data).map_err(|e| e.to_string())?;
    out.extend_from_slice(b",\"chunks\":");
    if count == 0 {
        out.push(b'[');
    } else {
        out.append(&mut chunks);
    }
    out.extend_from_slice(format!("],\"cursor\":{cursor},\"more\":{more}").as_bytes());
    for key in ["status", "cols", "rows"] {
        out.extend_from_slice(format!(",\"{key}\":{}", terminal[key]).as_bytes());
    }
    out.push(b'}');
    String::from_utf8(out).map(Value::String).map_err(|e| e.to_string())
}
fn handle(db: &mut Connection, r: &Request) -> Result<Value, String> {
    let a = &r.args;
    if let Some(result) = read(db, r) {
        return result;
    }
    match r.op.as_str() {
        op if op.starts_with("workspace_deletion_") => deletions::handle(db, op, a),
        #[cfg(test)]
        "test_slow_commit" => {
            let tx=db.transaction().map_err(|e|e.to_string())?;
            tx.execute("INSERT INTO agents(id,data) VALUES('injected','{}')",[]).map_err(|e|e.to_string())?;
            performance::commit(|| { let (lock,cv)=&TEST_COMMIT_GATE; let mut released=lock.lock().unwrap(); while !*released { released=cv.wait(released).unwrap(); } tx.commit() }).map_err(|e|e.to_string())?;
            Ok(Value::Null)
        },
        "barrier" => Ok(json!({})),
        "put" => {
            let tx = db.transaction().map_err(|e| e.to_string())?;
            put(&tx, table(a)?, &a["value"], a.get("notification"))?;
            performance::commit(|| tx.commit()).map_err(|e| e.to_string())?;
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
            performance::commit(|| tx.commit()).map_err(|e| e.to_string())?;
            Ok(json!(true))
        }
        "put_pair" => {
            let tx = db.transaction().map_err(|e| e.to_string())?;
            put(&tx, "projects", &a["project"], None)?;
            put(&tx, "workspaces", &a["workspace"], None)?;
            performance::commit(|| tx.commit()).map_err(|e| e.to_string())?;
            Ok(Value::Null)
        }
        "delete_workspace" => {
            let tx = db.transaction().map_err(|e| e.to_string())?;
            delete_workspace(&tx, a["id"].as_str().ok_or("id")?)?;
            performance::commit(|| tx.commit()).map_err(|e| e.to_string())?;
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
            performance::commit(|| tx.commit()).map_err(|e| e.to_string())?;
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
            performance::commit(|| tx.commit()).map_err(|e| e.to_string())?;
            Ok(Value::Null)
        }
        "operation" => {
            let mut statement = db
                .prepare_cached("SELECT id,hash,status,result FROM operations WHERE id=?")
                .map_err(|e| e.to_string())?;
            let mut rows = statement.query([a["id"].as_str()]).map_err(|e| e.to_string())?;
            let Some(row) = rows.next().map_err(|e| e.to_string())? else {
                return Ok(Value::Null);
            };
            let text = |i| row.get::<_, Option<String>>(i).map_err(|e| e.to_string());
            Ok(json!({"id":text(0)?,"hash":text(1)?,"status":text(2)?,"result":text(3)?}))
        }
        "operation_start" => {
            db.prepare_cached("INSERT INTO operations(id,hash,status) VALUES(?,?,'pending')")
                .and_then(|mut q| q.execute(params![a["id"].as_str(), a["hash"].as_str()]))
                .map_err(|e| e.to_string())?;
            Ok(Value::Null)
        }
        "operation_finish" => {
            db.prepare_cached("UPDATE operations SET status=?,result=? WHERE id=?")
                .and_then(|mut q| q.execute(params![a["status"].as_str(), a["result"].as_str(), a["id"].as_str()]))
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
                performance::commit(|| tx.commit()).map_err(|e| e.to_string())?;
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
            performance::commit(|| tx.commit()).map_err(|e| e.to_string())?;
            Ok(json!({}))
        }
        "append" => {
            let tx = db.transaction().map_err(|e| e.to_string())?;
            {
                let mut insert = tx
                    .prepare_cached("INSERT INTO output(terminalId,data,cols,rows) VALUES(?,?,?,?)")
                    .map_err(|e| e.to_string())?;
                // The PTY path supplies typed rows; the JSON form remains for other callers.
                for row in &r.rows {
                    insert
                        .execute(params![
                            row.terminal_id,
                            row.data,
                            row.size.map(|s| i64::from(s.0)),
                            row.size.map(|s| i64::from(s.1))
                        ])
                        .map_err(|e| e.to_string())?;
                }
                if r.rows.is_empty() {
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
            }
            performance::commit(|| tx.commit()).map_err(|e| e.to_string())?;
            Ok(json!({}))
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
    trace: Option<String>,
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
    if let Some(id)=&job.trace { performance::event(id,"store.sqlite.end"); }
    if result.is_ok() && (job.request.op != "compare_put" || result.as_ref().ok() == Some(&Value::Bool(true))) {
        if let Some(change) = change(&job.request) { let _ = changes.send(change); }
    }
    let _ = job.reply.send(result);
}
// Returns false only if rollback could not restore autocommit. The writer then
// closes its queues rather than processing further jobs in an uncertain tx.
fn execute_group(db: &mut Connection, jobs: Vec<Job>, changes: &broadcast::Sender<Change>) -> bool {
    let _scope = performance::StoreScope::enter(jobs.iter().filter_map(|j|j.trace.clone()).collect());
    if jobs.len() == 1 {
        let job = jobs.into_iter().next().unwrap();
        let implicit=groupable(&job)&&db.is_autocommit();
        if implicit { performance::mark("store.autocommit.begin"); }
        let result = handle(db, &job.request).map_err(|_| ApiError::storage());
        if implicit { performance::mark("store.autocommit.end"); }
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
            let committed = performance::commit(|| db.execute_batch("COMMIT")).is_ok();
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
fn serve_reads(mut rx: mpsc::Receiver<Job>, db: Connection) {
    while let Some(job) = rx.blocking_recv() {
        let _scope = performance::StoreScope::enter(job.trace.iter().cloned().collect());
        // One deferred transaction pins a single committed snapshot for every
        // statement of the request. Replies follow commit, so a caller always
        // observes the writes whose replies it has already received.
        let result = db
            .unchecked_transaction()
            .map_err(|e| e.to_string())
            .and_then(|tx| read(&tx, &job.request).unwrap_or_else(|| Err("not a read".into())))
            .map_err(|_| ApiError::storage());
        if let Some(id) = &job.trace {
            performance::event(id, "store.sqlite.end");
        }
        let _ = job.reply.send(result);
    }
}
#[derive(Clone)]
pub struct StoreHandle {
    events:broadcast::Sender<Change>,
    writes: mpsc::Sender<Job>,
    bulk: mpsc::Sender<Job>,
    reads: mpsc::Sender<Job>,
    state_reads: mpsc::Sender<Job>,
    credit: Arc<Semaphore>,
    bulk_credit: Arc<Semaphore>,
    enqueue: Arc<tokio::sync::RwLock<()>>,
}
impl StoreHandle {
    pub async fn open(path: &Path, events: broadcast::Sender<Change>) -> Result<Self, ApiError> {
        let path = path.to_owned();
        let (writes, mut rx) = mpsc::channel::<Job>(64);
        let (bulk, mut bulk_rx) = mpsc::channel::<Job>(128);
        let (reads, read_rx) = mpsc::channel::<Job>(16);
        let (state_reads, state_rx) = mpsc::channel::<Job>(16);
        let (ready, ready_rx) = oneshot::channel();
        let changes=events.clone();
        std::thread::Builder::new().name("native-store".into()).spawn(move||{
   let init=(||->Result<(Connection,Connection,Connection),String>{let writer=Connection::open(&path).map_err(|e|e.to_string())?;writer.execute_batch(SCHEMA).map_err(|e|e.to_string())?;let columns:Vec<String>=writer.prepare("PRAGMA table_info(output)").map_err(|e|e.to_string())?.query_map([],|r|r.get(1)).map_err(|e|e.to_string())?.collect::<rusqlite::Result<_>>().map_err(|e|e.to_string())?;if !columns.iter().any(|c|c=="cols"){writer.execute_batch("ALTER TABLE output ADD COLUMN cols INTEGER; ALTER TABLE output ADD COLUMN rows INTEGER;").map_err(|e|e.to_string())?;}writer.set_prepared_statement_cache_capacity(64);
    // Terminal output and state snapshots each have a read-only connection, so
    // neither waits behind the writer's commits or behind the other's pages.
    // A large transaction such as a history purge otherwise leaves the WAL file at
    // its high-water mark indefinitely. Durability and checkpointing are unchanged.
    writer.execute_batch("PRAGMA journal_size_limit=67108864;").map_err(|e|e.to_string())?;
    let reader=|| -> Result<Connection,String> {let reader=Connection::open(&path).map_err(|e|e.to_string())?;reader.execute_batch("PRAGMA query_only=ON;PRAGMA busy_timeout=5000;").map_err(|e|e.to_string())?;reader.set_prepared_statement_cache_capacity(32);Ok(reader)};
    Ok((writer,reader()?,reader()?))})();
   let Ok((mut writer,reader,state_reader))=init else {let _=ready.send(false);return;};
   let started=[("native-output-read",read_rx,reader),("native-state-read",state_rx,state_reader)].into_iter().all(|(name,rx,db)|std::thread::Builder::new().name(name.into()).spawn(move||serve_reads(rx,db)).is_ok());
   let _=ready.send(started);
   if !started {return;}
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
            state_reads,
            credit: Arc::new(Semaphore::new(4 * 1024 * 1024)),
            bulk_credit: Arc::new(Semaphore::new(12 * 1024 * 1024)),
            enqueue: Arc::new(tokio::sync::RwLock::new(())),
        };
        store.call("recover", json!({})).await?;
        Ok(store)
    }
    pub fn signal_change(&self,change:Change){let _=self.events.send(change);}
    pub async fn call(&self, op: &str, args: Value) -> Result<Value, ApiError> {
        let trace=performance::context();
        if let Some(id)=&trace { performance::event(id,"store.queue.begin"); }
        if op == "barrier" {
            // Exclude new enqueues while FIFO fences pass through both lanes. Jobs already
            // awaiting credits are not accepted yet and therefore fall after this barrier.
            let _gate = self.enqueue.write().await;
            for tx in [&self.bulk, &self.writes] {
                let (reply, rx) = oneshot::channel();
                tx.send(Job {
                    trace: trace.clone(),
                    request: Request::new("barrier", Value::Null),
                    reply,
                    _credit: None,
                })
                .await
                .map_err(|_| ApiError::storage())?;
                rx.await.map_err(|_| ApiError::storage())??;
            }
            return Ok(json!({}));
        }
        let mut bytes = ByteCount(0);
        serde_json::to_writer(&mut bytes, &args).map_err(|_| ApiError::storage())?;
        self.submit(Request::new(op, args), bytes.0, trace).await
    }
    /// Durably appends PTY output in order. Credits use the raw byte length.
    pub async fn append(&self, rows: Vec<OutputRow>) -> Result<(), ApiError> {
        let trace=performance::context();
        if let Some(id)=&trace { performance::event(id,"store.queue.begin"); }
        let bytes = rows.iter().map(|r| r.terminal_id.len() + r.data.len() + 16).sum();
        self.submit(Request { op: "append".into(), args: Value::Null, rows }, bytes, trace).await.map(|_| ())
    }
    async fn submit(&self, request: Request, bytes: usize, trace: Option<String>) -> Result<Value, ApiError> {
        let bytes = bytes.max(1);
        let op = request.op.as_str();
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
        // `operation` stays on the writer: a retry must observe an accepted
        // operation_start even when its first caller went away before the reply.
        let tx = match op {
            "output" | "output_page" => &self.reads,
            "get" | "list" | "state" | "state_json" | "notifications" | "events" => &self.state_reads,
            _ if bulk => &self.bulk,
            _ => &self.writes,
        };
        let job = Job {
            trace,
            request,
            reply,
            _credit: Some(credit),
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
            // One entry per terminal, however many chunks the batch carried.
            terminals: {
                let mut ids: Vec<String> = Vec::new();
                let typed = r.rows.iter().map(|row| row.terminal_id.as_str());
                let json = a.as_array().into_iter().flatten().filter_map(|row| row["terminalId"].as_str());
                for id in typed.chain(json) {
                    if !ids.iter().any(|known| known == id) {
                        ids.push(id.to_owned());
                    }
                }
                ids
            },
            agent_terminals: vec![],
            browser: false,
        }),
        "pty_exit" => Some(Change {
            state: true,
            terminals: vec![a["terminalId"].as_str()?.to_owned()],
            agent_terminals: vec![],
            browser: false,
        }),
        "workspace_deletion_accept" | "workspace_deletion_retry" | "workspace_deletion_update" | "put_pair" | "delete_workspace" | "remove_project" => Some(Change {
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
            &Request::new("put", json!({"table":"workspaces","value":old})),
        )
        .unwrap();
        let args = json!({"table":"workspaces","id":"w","expected":old,"value":{"id":"w","title":"manual"}});
        assert_eq!(
            handle(
                &mut db,
                &Request::new("compare_put", args.clone())
            )
            .unwrap(),
            true
        );
        let revision = query(&db, "SELECT MAX(sequence) AS n FROM events", &[]).unwrap();
        assert_eq!(
            handle(
                &mut db,
                &Request::new("compare_put", args)
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
            &Request::new("compare_put", json!({"table":"workspaces","id":"w","expected":null,"value":{"id":"other"}}))
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
        (Job { trace: None, request: Request::new(op, args), reply, _credit: None }, rx)
    }
    fn start(id: &str) -> (Job, oneshot::Receiver<Result<Value, ApiError>>) {
        job("operation_start", json!({"id":id,"hash":"h"}))
    }
    fn db() -> Connection {
        let mut db = Connection::open_in_memory().unwrap();
        db.execute_batch(SCHEMA).unwrap();
        // Keep the same handle API exercised by the real writer.
        handle(&mut db, &Request::new("barrier", Value::Null)).unwrap();
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

#[cfg(test)]
mod trace_tests {
    use super::*;
    #[tokio::test]
    async fn injected_commit_and_queue_have_separate_correlated_intervals() {
        if std::env::var_os("NEURA_TRACE_TEST_CHILD").is_none() {
            let dir=std::env::temp_dir().join(format!("neura-trace-{}",uuid::Uuid::new_v4()));
            let result=std::process::Command::new(std::env::current_exe().unwrap())
                .args(["--exact","store::trace_tests::injected_commit_and_queue_have_separate_correlated_intervals","--nocapture"])
                .env("NEURA_TRACE_TEST_CHILD","1").env("NEURA_PERF_TRACE_DIR",&dir).output().unwrap();
            assert!(result.status.success(),"{}",String::from_utf8_lossy(&result.stderr));
            std::fs::remove_dir_all(dir).unwrap();
            return;
        }
        let dir=std::path::PathBuf::from(std::env::var_os("NEURA_PERF_TRACE_DIR").unwrap());
        std::fs::create_dir_all(&dir).unwrap();
        let (changes,_)=broadcast::channel(16);
        let store=StoreHandle::open(&dir.join("fixture.sqlite"),changes).await.unwrap();
        let a=uuid::Uuid::new_v4().to_string();let b=uuid::Uuid::new_v4().to_string();
        let writer=store.clone();let id=a.clone();
        let slow=tokio::spawn(async move{performance::REQUEST.scope(id,writer.call("test_slow_commit",json!({}))).await.unwrap()});
        async fn wait_event(dir:&std::path::Path,id:&str,event:&str) {
            for _ in 0..500 {
                performance::flush().await;
                if std::fs::read_to_string(dir.join("daemon.jsonl")).unwrap_or_default().lines().any(|l|{
                    let r:Value=serde_json::from_str(l).unwrap();r["requestId"]==id&&r["event"]==event
                }) { return; }
                tokio::time::sleep(std::time::Duration::from_millis(10)).await;
            }
            panic!("trace stage did not arrive");
        }
        wait_event(&dir,&a,"store.commit.begin").await;
        let reader=store.clone();let id=b.clone();
        let queued=tokio::spawn(async move{performance::REQUEST.scope(id,reader.call("operation",json!({"id":"queued-behind-commit"}))).await.unwrap()});
        wait_event(&dir,&b,"store.queue.begin").await;
        tokio::time::sleep(std::time::Duration::from_millis(120)).await;
        *TEST_COMMIT_GATE.0.lock().unwrap()=true;TEST_COMMIT_GATE.1.notify_one();
        queued.await.unwrap();slow.await.unwrap();performance::flush().await;
        let text=std::fs::read_to_string(dir.join("daemon.jsonl")).unwrap();
        let rows:Vec<Value>=text.lines().map(|l|serde_json::from_str(l).unwrap()).collect();
        let at=|id:&str,event:&str|rows.iter().find(|r|r["requestId"]==id&&r["event"]==event).unwrap()["monotonicMs"].as_f64().unwrap();
        assert!(at(&a,"store.commit.end")-at(&a,"store.commit.begin")>=100.);
        assert!(at(&b,"store.sqlite.begin")-at(&b,"store.queue.begin")>=100.);
        assert!(!rows.iter().any(|r|r["requestId"]==b&&r["event"]=="store.commit.begin"));
        assert!(!text.contains("injected"));assert!(!text.contains("SELECT"));
        drop(store);
    }
}

#[cfg(test)]
mod read_lane_tests {
    use super::*;
    fn fixture() -> Connection {
        let mut db = Connection::open_in_memory().unwrap();
        db.execute_batch(SCHEMA).unwrap();
        for (table, value) in [
            ("projects", json!({"id":"p","name":"引用\"符\\と改行\n","path":"/tmp/p"})),
            ("workspaces", json!({"id":"w","projectId":"p","kind":"root"})),
            ("workspaces", json!({"id":"w2","projectId":"p","kind":"worktree"})),
            ("terminals", json!({"id":"t","workspaceId":"w","status":"running","cols":100,"rows":30})),
            ("terminals", json!({"id":"bare","workspaceId":"w"})),
        ] {
            handle(&mut db, &Request::new("put", json!({"table":table,"value":value}))).unwrap();
        }
        db
    }
    fn page(db: &Connection, args: Value) -> Value {
        let text = output_page(db, &args).unwrap();
        serde_json::from_str(text.as_str().unwrap()).unwrap()
    }
    #[test]
    fn encoded_state_and_output_pages_equal_the_value_forms() {
        let mut db = fixture();
        let args = json!({"hostName":"ホスト\"名"});
        let expected = handle(&mut db, &Request::new("state", args.clone())).unwrap();
        let parse = |db: &Connection| -> Value {
            serde_json::from_str(&(state_json(db, &args).unwrap() + "}")).unwrap()
        };
        assert_eq!(parse(&db), expected);
        assert_eq!(expected["terminals"].as_array().unwrap().len(), 2);
        // With a deletion job the workspace overlay must appear exactly as before.
        db.execute("INSERT INTO workspace_deletions(id,workspace_id,status,blocks,public,data) VALUES('j','w2','running',1,?,'{}')",[json!({"id":"j","status":"running"}).to_string()]).unwrap();
        let overlaid = handle(&mut db, &Request::new("state", args.clone())).unwrap();
        assert_eq!(overlaid["workspaces"][1]["deletion"]["status"], "running");
        assert_eq!(parse(&db), overlaid);
        // Corrupt stored rows fail closed instead of being forwarded as text.
        db.execute("UPDATE projects SET data='{broken'", []).unwrap();
        assert!(state_json(&db, &args).is_err());

        // Typed rows, a resize marker, escapes, multi-byte text and the JSON form.
        let rows = vec![
            OutputRow { terminal_id: "t".into(), data: "plain\r\n\u{1b}[31m\"quoted\"\\\u{0}".into(), size: None },
            OutputRow { terminal_id: "other".into(), data: "not mine".into(), size: None },
            OutputRow { terminal_id: "t".into(), data: String::new(), size: Some((47, 19)) },
            OutputRow { terminal_id: "t".into(), data: "日本語🙂".into(), size: None },
        ];
        let typed = Request { op: "append".into(), args: Value::Null, rows };
        assert_eq!(change(&typed).unwrap().terminals, ["t", "other"]);
        handle(&mut db, &typed).unwrap();
        handle(&mut db, &Request::new("append", json!([{"terminalId":"t","data":"json"},{"terminalId":"t","data":"","cols":80,"rows":24}]))).unwrap();
        for chunks_only in [false, true] {
            let args = json!({"terminalId":"t","after":0,"chunksOnly":chunks_only});
            let mut expected = output(&db, &args).unwrap();
            expected["status"] = json!("running");
            expected["cols"] = json!(100);
            expected["rows"] = json!(30);
            assert_eq!(page(&db, args), expected);
            assert_eq!(expected["chunks"].as_array().unwrap().len(), 5);
            assert_eq!(expected["chunks"][1]["cols"], 47);
        }
        // Cursor paging, a terminal without optional fields, and a missing terminal.
        let rest = page(&db, json!({"terminalId":"t","after":4,"chunksOnly":true}));
        assert_eq!(rest["chunks"].as_array().unwrap().len(), 2);
        assert_eq!(rest["cursor"], 6);
        let bare = page(&db, json!({"terminalId":"bare","after":0}));
        assert_eq!(bare, json!({"data":"","chunks":[],"cursor":0,"more":false,"status":null,"cols":null,"rows":null}));
        assert_eq!(output_page(&db, &json!({"terminalId":"missing","after":0})).unwrap(), Value::Null);
        // The same byte and row limits decide `more` in both forms.
        let big = "x".repeat(100 * 1024);
        for _ in 0..4 {
            handle(&mut db, &Request { op: "append".into(), args: Value::Null, rows: vec![OutputRow { terminal_id: "bare".into(), data: big.clone(), size: None }] }).unwrap();
        }
        let args = json!({"terminalId":"bare","after":0,"chunksOnly":true});
        let limited = page(&db, args.clone());
        assert_eq!(limited["more"], true);
        assert_eq!(limited["chunks"].as_array().unwrap().len(), 3);
        assert_eq!(limited["chunks"], output(&db, &args).unwrap()["chunks"]);
    }
    #[tokio::test]
    async fn reads_do_not_wait_for_a_writer_inside_a_commit_and_observe_replied_writes() {
        let dir = std::env::temp_dir().join(format!("neura-store-read-lane-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&dir).unwrap();
        let (events, _) = broadcast::channel(8);
        let store = StoreHandle::open(&dir.join("test.sqlite"), events).await.unwrap();
        store.put("terminals", json!({"id":"t","status":"running","cols":80,"rows":24}), None).await.unwrap();
        store.append(vec![OutputRow { terminal_id: "t".into(), data: "before".into(), size: None }]).await.unwrap();
        // FULL/WAL durability is unchanged; only the idle WAL file size is bounded.
        let pragma = |sql: &'static str| { let store = store.clone(); async move { store.call("query", json!({"sql":sql,"args":[]})).await.unwrap()[0].clone() } };
        assert_eq!(pragma("PRAGMA synchronous").await["synchronous"], 2);
        assert_eq!(pragma("PRAGMA journal_mode").await["journal_mode"], "wal");
        assert_eq!(pragma("PRAGMA journal_size_limit").await["journal_size_limit"], 64 * 1024 * 1024);
        // The writer enters an explicit commit and stays there; a second write queues behind it.
        let writer = store.clone();
        let slow = tokio::spawn(async move { writer.call("test_slow_commit", json!({})).await });
        let writer = store.clone();
        let queued = tokio::spawn(async move { writer.put("projects", json!({"id":"p"}), None).await });
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        let reads = async {
            let state = store.call("state_json", json!({"hostName":"h"})).await.unwrap();
            let state: Value = serde_json::from_str(&(state.as_str().unwrap().to_owned() + "}")).unwrap();
            assert_eq!(state["terminals"][0]["id"], "t");
            assert_eq!(state["projects"], json!([]));
            assert_eq!(store.call("state", json!({"hostName":"h"})).await.unwrap(), state);
            assert_eq!(store.get("terminals", "t").await.unwrap().unwrap()["cols"], 80);
            assert_eq!(store.list("terminals").await.unwrap().len(), 1);
            assert_eq!(store.call("events", json!({"after":0})).await.unwrap().as_array().unwrap().len(), 1);
            assert_eq!(store.call("notifications", json!({"after":0})).await.unwrap()["events"], json!([]));
            let page = store.call("output_page", json!({"terminalId":"t","after":0,"chunksOnly":true})).await.unwrap();
            let page: Value = serde_json::from_str(page.as_str().unwrap()).unwrap();
            assert_eq!(page["chunks"][0]["data"], "before");
            assert_eq!(page["status"], "running");
        };
        tokio::time::timeout(std::time::Duration::from_secs(5), reads).await.expect("reads waited for the writer");
        assert!(!slow.is_finished() && !queued.is_finished());
        *TEST_COMMIT_GATE.0.lock().unwrap() = true;
        TEST_COMMIT_GATE.1.notify_all();
        slow.await.unwrap().unwrap();
        queued.await.unwrap().unwrap();
        // A write whose reply has been received is visible to the very next read.
        for round in 0..50 {
            store.put("projects", json!({"id":"p","round":round}), None).await.unwrap();
            assert_eq!(store.get("projects", "p").await.unwrap().unwrap()["round"], round);
            store.append(vec![OutputRow { terminal_id: "t".into(), data: round.to_string(), size: None }]).await.unwrap();
            let page = store.call("output_page", json!({"terminalId":"t","after":0,"chunksOnly":true})).await.unwrap();
            let page: Value = serde_json::from_str(page.as_str().unwrap()).unwrap();
            assert_eq!(page["chunks"].as_array().unwrap().last().unwrap()["data"], round.to_string());
        }
        store.update("projects", "p", |p| p["round"] = json!("cas")).await.unwrap();
        assert_eq!(store.get("projects", "p").await.unwrap().unwrap()["round"], "cas");
        drop(store);
        let _ = std::fs::remove_dir_all(dir);
    }
}
