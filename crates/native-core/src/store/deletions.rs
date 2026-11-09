//! All job/operation/workspace transitions commit together in the Store writer.
use super::*;
fn one(db: &Connection, id: &str) -> Result<Value, String> {
    Ok(records(db, "workspace_deletions", Some(id))?
        .as_array()
        .unwrap()
        .first()
        .cloned()
        .unwrap_or(Value::Null))
}
fn timestamp() -> String {
    chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
}
fn save(db: &Connection, job: &mut Value) -> Result<(), String> {
    job["public"]["revision"] = json!(job["public"]["revision"].as_u64().unwrap_or(0) + 1);
    job["public"]["updatedAt"] = json!(timestamp());
    db.execute("INSERT INTO workspace_deletions(id,workspace_id,status,blocks,public,data) VALUES(?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET status=excluded.status,blocks=excluded.blocks,public=excluded.public,data=excluded.data",params![job["id"].as_str(),job["public"]["workspaceId"].as_str(),job["public"]["status"].as_str(),job["public"]["blocksWorkspace"]==true,job["public"].to_string(),job.to_string()]).map_err(|e|e.to_string())?;
    db.execute(
        "INSERT INTO events(kind,entityId,at) VALUES('workspaces',?,?)",
        params![job["public"]["workspaceId"].as_str(), timestamp()],
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}
fn error(code: &str) -> Value {
    json!({"error":code})
}
pub(super) fn gate(db: &Connection, workspace: &str) -> Result<Value, String> {
    let rows = query(db,"SELECT id FROM workspace_deletions WHERE workspace_id=? AND blocks=1 ORDER BY rowid DESC LIMIT 1",&[json!(workspace)])?;
    Ok(rows
        .as_array()
        .unwrap()
        .first()
        .map(|j| json!({"blocked":true,"jobId":j["id"]}))
        .unwrap_or(json!({"blocked":false})))
}
pub(super) fn overlay(db: &Connection, rows: &mut [Value]) -> Result<(), String> {
    // Only one indexed public row per workspace; never decode historical internal payloads.
    let mut statement=db.prepare_cached("SELECT public FROM workspace_deletions WHERE workspace_id=? ORDER BY rowid DESC LIMIT 1").map_err(|e|e.to_string())?;
    for row in rows {
        let mut result = statement
            .query([row["id"].as_str().ok_or("id")?])
            .map_err(|e| e.to_string())?;
        if let Some(r) = result.next().map_err(|e| e.to_string())? {
            let value: String = r.get(0).map_err(|e| e.to_string())?;
            row["deletion"] = serde_json::from_str(&value).map_err(|e| e.to_string())?;
        }
    }
    Ok(())
}
pub(super) fn handle(db: &mut Connection, op: &str, a: &Value) -> Result<Value, String> {
    match op {
        "workspace_deletion_gate" => gate(db, a["workspaceId"].as_str().ok_or("workspaceId")?),
        "workspace_deletion_get" => one(db, a["id"].as_str().ok_or("id")?),
        "workspace_deletion_list" => {
            let rows = query(
                db,
                "SELECT data FROM workspace_deletions WHERE status IN ('queued','running')",
                &[],
            )?;
            rows.as_array()
                .unwrap()
                .iter()
                .map(|r| {
                    serde_json::from_str::<Value>(r["data"].as_str().unwrap())
                        .map_err(|e| e.to_string())
                })
                .collect::<Result<Vec<_>, _>>()
                .map(Value::Array)
        }
        "workspace_deletion_accept" | "workspace_deletion_retry" => {
            let tx = db.transaction().map_err(|e| e.to_string())?;
            let id = a["operationId"].as_str().ok_or("operationId")?;
            let prior = query(
                &tx,
                "SELECT hash,result,status FROM operations WHERE id=?",
                &[json!(id)],
            )?;
            if let Some(prior) = prior.as_array().unwrap().first() {
                if prior["hash"] != a["hash"] {
                    return Ok(error("operation_conflict"));
                }
                let result: Value =
                    serde_json::from_str(prior["result"].as_str().unwrap_or("null"))
                        .map_err(|e| e.to_string())?;
                if let Some(job) = result["workspaceDeletion"].as_str() {
                    return one(&tx, job);
                }
                return Ok(error("operation_unknown"));
            }
            let mut job;
            if op == "workspace_deletion_retry" {
                job = one(&tx, a["jobId"].as_str().ok_or("jobId")?)?;
                if job.is_null() {
                    return Ok(error("deletion_missing"));
                }
                if job["public"]["status"] == "failed" {
                    if job["public"]["retryable"] != true {
                        return Ok(error("deletion_not_retryable"));
                    }
                    let wid = job["public"]["workspaceId"].as_str().ok_or("workspaceId")?;
                    let blocking = gate(&tx, wid)?;
                    if blocking["blocked"] == true && blocking["jobId"] != job["id"] {
                        return Ok(error("workspace_deleting"));
                    }
                    // A newer safe attempt must not be superseded by an older retry.
                    let latest=query(&tx,"SELECT id FROM workspace_deletions WHERE workspace_id=? ORDER BY rowid DESC LIMIT 1",&[json!(wid)])?;
                    if latest
                        .as_array()
                        .unwrap()
                        .first()
                        .is_some_and(|j| j["id"] != job["id"])
                    {
                        return Ok(error("deletion_superseded"));
                    }
                    job["public"]["status"] = json!("queued");
                    job["public"]["blocksWorkspace"] = json!(true);
                    job["public"].as_object_mut().unwrap().remove("error");
                    save(&tx, &mut job)?;
                }
            } else {
                let wid = a["command"]["workspaceId"].as_str().ok_or("workspaceId")?;
                let existing_rows=query(&tx,"SELECT data FROM workspace_deletions WHERE workspace_id=? AND (blocks=1 OR status='succeeded') ORDER BY rowid DESC LIMIT 1",&[json!(wid)])?;
                let existing = existing_rows
                    .as_array()
                    .unwrap()
                    .first()
                    .map(|row| {
                        serde_json::from_str::<Value>(row["data"].as_str().unwrap())
                            .map_err(|e| e.to_string())
                    })
                    .transpose()?;
                if let Some(existing) = existing {
                    if existing["command"] != a["command"] {
                        return Ok(error("workspace_deletion_conflict"));
                    }
                    job = existing.clone();
                } else {
                    let mut w = records(&tx, "workspaces", Some(wid))?
                        .as_array()
                        .unwrap()
                        .first()
                        .cloned()
                        .unwrap_or(Value::Null);
                    if w.is_null() {
                        return Ok(error("workspace_missing"));
                    }
                    if w["kind"] != "worktree" {
                        return Ok(error("worktree_required"));
                    }
                    w.as_object_mut().unwrap().remove("deletion");
                    let latest=query(&tx,"SELECT public FROM workspace_deletions WHERE workspace_id=? ORDER BY rowid DESC LIMIT 1",&[json!(wid)])?;
                    let generation = latest
                        .as_array()
                        .unwrap()
                        .first()
                        .map(|r| {
                            serde_json::from_str::<Value>(r["public"].as_str().unwrap())
                                .map_err(|e| e.to_string())
                        })
                        .transpose()?
                        .and_then(|j| j["generation"].as_u64())
                        .unwrap_or(0)
                        + 1;
                    let now = timestamp();
                    job = json!({"id":id,"command":a["command"],"workspace":w,"public":{"id":id,"workspaceId":wid,"status":"queued","phase":"queued","revision":0,"generation":generation,"createdAt":now,"updatedAt":now,"retryable":true,"blocksWorkspace":true}});
                    save(&tx, &mut job)?;
                }
            }
            tx.execute(
                "INSERT INTO operations(id,hash,status,result) VALUES(?,?,'done',?)",
                params![
                    id,
                    a["hash"].as_str(),
                    json!({"workspaceDeletion":job["id"]}).to_string()
                ],
            )
            .map_err(|e| e.to_string())?;
            performance::commit(|| tx.commit()).map_err(|e| e.to_string())?;
            Ok(job)
        }
        "workspace_deletion_purge" => {
            let tx = db.transaction().map_err(|e| e.to_string())?;
            let job = one(&tx, a["id"].as_str().ok_or("id")?)?;
            if job["removalStarted"] != true
                || job["public"]["phase"] != "finalize"
                || job["public"]["status"] != "running"
            {
                return Ok(error("deletion_changed"));
            }
            let wid = job["public"]["workspaceId"].clone();
            let terminals=query(&tx,"SELECT id FROM terminals WHERE json_extract(data,'$.workspaceId')=? ORDER BY rowid",&[wid])?;
            let mut removed = 0;
            for terminal in terminals.as_array().unwrap() {
                let id = terminal["id"].as_str().ok_or("id")?;
                // Bound payload as well as row count: append rows can be large.
                // At most 256 KiB or 256 rows (one oversized row is unavoidable).
                let rows=query(&tx,"SELECT sequence,length(CAST(data AS BLOB)) AS bytes FROM output WHERE terminalId=? ORDER BY sequence LIMIT 256",&[json!(id)])?;
                let mut bytes = 0;
                let mut last = None;
                for row in rows.as_array().unwrap() {
                    bytes += row["bytes"].as_u64().unwrap_or(0);
                    last = row["sequence"].as_i64();
                    if bytes >= 262144 {
                        break;
                    }
                }
                if let Some(last) = last {
                    removed = tx
                        .execute(
                            "DELETE FROM output WHERE terminalId=? AND sequence<=?",
                            params![id, last],
                        )
                        .map_err(|e| e.to_string())?;
                } else {
                    removed=tx.execute("DELETE FROM notification_events WHERE sequence IN (SELECT sequence FROM notification_events WHERE terminalId=? ORDER BY sequence LIMIT 256)",[id]).map_err(|e|e.to_string())?;
                }
                if removed > 0 {
                    break;
                }
            }
            performance::commit(|| tx.commit()).map_err(|e| e.to_string())?;
            Ok(json!({"done":removed==0,"removed":removed}))
        }
        "workspace_deletion_update" => {
            let tx = db.transaction().map_err(|e| e.to_string())?;
            let mut job = one(&tx, a["id"].as_str().ok_or("id")?)?;
            if job.is_null() || job["public"]["revision"] != a["revision"] {
                return Ok(error("deletion_changed"));
            }
            for (key, value) in a["patch"].as_object().ok_or("patch")? {
                if key == "public" {
                    for (key, value) in value.as_object().ok_or("public")? {
                        job["public"][key] = value.clone();
                    }
                } else {
                    job[key] = value.clone();
                }
            }
            save(&tx, &mut job)?;
            if job["public"]["status"] == "succeeded" {
                delete_workspace(
                    &tx,
                    job["public"]["workspaceId"].as_str().ok_or("workspaceId")?,
                )?;
            }
            performance::commit(|| tx.commit()).map_err(|e| e.to_string())?;
            Ok(job)
        }
        _ => Err("unknown deletion op".into()),
    }
}
