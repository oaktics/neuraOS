use super::agents::Agents;
use super::{now, tail, Result};
use notify::{RecursiveMode, Watcher};
use serde_json::{json, Value};
use std::{
    collections::{HashMap, HashSet},
    fs::File,
    io::{Read, Seek, SeekFrom, Write},
    os::unix::fs::MetadataExt,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
};
use tokio::sync::Notify;

#[derive(Clone, Debug, PartialEq, Eq)]
struct Snapshot {
    dev: u64,
    ino: u64,
    size: u64,
    mtime: i64,
    mtime_ns: i64,
    ctime: i64,
    ctime_ns: i64,
}
impl Snapshot {
    fn from(m: std::fs::Metadata) -> Self {
        Self {
            dev: m.dev(),
            ino: m.ino(),
            size: m.len(),
            mtime: m.mtime(),
            mtime_ns: m.mtime_nsec(),
            ctime: m.ctime(),
            ctime_ns: m.ctime_nsec(),
        }
    }
}
#[derive(Default)]
pub struct CompletionReader {
    snapshot: Option<Snapshot>,
    session: String,
    after: i64,
    summary: Option<String>,
    completed: Option<Value>,
    pub bytes_read: u64,
    pub title: Option<(String, i64)>,
}
impl CompletionReader {
    pub fn read(&mut self, path: &Path, session: &str, after: i64) -> Result<Option<Value>> {
        let mut file = match File::open(path) {
            Ok(f) => f,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(e.to_string()),
        };
        let before = Snapshot::from(file.metadata().map_err(|e| e.to_string())?);
        let same = self.session == session
            && self.after == after
            && self.snapshot.as_ref().is_some_and(|s| {
                s.dev == before.dev && s.ino == before.ino && s.size <= before.size
            });
        if same && self.snapshot.as_ref() == Some(&before) {
            return Ok(None);
        }
        let incremental = same
            && self
                .snapshot
                .as_ref()
                .is_some_and(|s| s.size < before.size && before.size - s.size <= 512 * 1024);
        let start = if incremental {
            self.snapshot.as_ref().unwrap().size
        } else {
            before.size.saturating_sub(512 * 1024)
        };
        // Bounded chunk reads avoid allocation proportional to tool output bursts.
        file.seek(SeekFrom::Start(start))
            .map_err(|e| e.to_string())?;
        let mut bytes = Vec::new();
        file.take(before.size - start)
            .read_to_end(&mut bytes)
            .map_err(|e| e.to_string())?;
        self.bytes_read += bytes.len() as u64;
        if bytes.len() as u64 != before.size - start || bytes.last() != Some(&b'\n') {
            return Ok(None);
        }
        let Ok(text) = std::str::from_utf8(&bytes) else {
            return Ok(None);
        };
        let mut lines = text.split_terminator('\n');
        if start > 0 && !incremental {
            lines.next();
        }
        let mut summary = if incremental {
            self.summary.clone()
        } else {
            None
        };
        let mut completed = if incremental {
            self.completed.clone()
        } else {
            None
        };
        let mut title = if incremental {
            self.title.clone()
        } else {
            None
        };
        for line in lines {
            let row: Value = match serde_json::from_str(line) {
                Ok(v) => v,
                Err(_) => return Ok(None),
            };
            if row["isSidechain"] == true || row["sessionId"] != session {
                continue;
            }
            let name = match row["type"].as_str() {
                Some("custom-title") => row["customTitle"].as_str(),
                Some("ai-title") => row["aiTitle"].as_str(),
                _ => None,
            };
            if let Some(name) = name {
                let name = name
                    .split_whitespace()
                    .collect::<Vec<_>>()
                    .join(" ")
                    .chars()
                    .filter(|c| !c.is_control())
                    .take(200)
                    .collect::<String>();
                if !name.is_empty() {
                    title = Some((name, before.mtime * 1000 + before.mtime_ns / 1_000_000));
                }
            }
            let Some(timestamp) = row["timestamp"]
                .as_str()
                .and_then(|v| chrono::DateTime::parse_from_rfc3339(v).ok())
                .map(|v| v.timestamp_millis())
            else {
                continue;
            };
            if matches!(
                row["type"].as_str(),
                Some("user" | "assistant" | "api-request")
            ) {
                completed = None;
            }
            if row["type"] == "assistant" {
                summary = row["message"]["content"].as_array().map(|blocks| {
                    tail(
                        &blocks
                            .iter()
                            .filter(|b| b["type"] == "text")
                            .filter_map(|b| b["text"].as_str())
                            .collect::<Vec<_>>()
                            .join("\n"),
                        8000,
                    )
                });
            }
            if row["type"] == "system" && row["subtype"] == "turn_duration" && timestamp >= after {
                let mut e = json!({"hook_event_name":"Stop","session_id":session,"transcript_path":path,"observed_at":timestamp.to_string()});
                if let Some(summary) = &summary {
                    e["last_assistant_message"] = json!(summary);
                }
                completed = Some(e);
            }
        }
        let current = match std::fs::metadata(path) {
            Ok(m) => Snapshot::from(m),
            Err(_) => return Ok(None),
        };
        if before != current {
            return Ok(None);
        }
        self.title = title;
        self.snapshot = Some(before);
        self.session = session.into();
        self.after = after;
        self.summary = summary;
        self.completed = completed.clone();
        Ok(completed)
    }
}

/// One OS watcher and one reconciliation deadline serve all active transcripts.
/// Directory subscriptions preserve atomic replacement and inode fencing.
pub struct CompletionMonitor {
    watcher: Mutex<notify::RecommendedWatcher>,
    entries: Mutex<HashMap<String, PathBuf>>,
    dirty: Arc<Mutex<HashSet<PathBuf>>>,
    wake: Arc<Notify>,
    stop: Arc<Notify>,
}
impl CompletionMonitor {
    pub fn start(agents: Arc<Agents>) -> Result<Arc<Self>> {
        let dirty = Arc::new(Mutex::new(HashSet::new()));
        let wake = Arc::new(Notify::new());
        let d = dirty.clone();
        let w = wake.clone();
        let watcher = notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
            if let Ok(event) = event {
                d.lock().unwrap().extend(event.paths);
            } else {
                d.lock().unwrap().insert(PathBuf::new());
            }
            w.notify_one();
        })
        .map_err(|e| e.to_string())?;
        let this = Arc::new(Self {
            watcher: Mutex::new(watcher),
            entries: Mutex::new(HashMap::new()),
            dirty,
            wake,
            stop: Arc::new(Notify::new()),
        });
        let worker = this.clone();
        tokio::spawn(async move {
            let mut readers: HashMap<String, CompletionReader> = HashMap::new();
            loop {
                let sweep = tokio::select! {_ = worker.stop.notified()=>break,_=worker.wake.notified()=>false,_=tokio::time::sleep(std::time::Duration::from_secs(60))=>true};
                if !sweep {
                    tokio::time::sleep(std::time::Duration::from_millis(40)).await;
                }
                let dirty = std::mem::take(&mut *worker.dirty.lock().unwrap());
                let entries = worker.entries.lock().unwrap().clone();
                readers.retain(|k, _| entries.contains_key(k));
                for (terminal, path) in entries {
                    if !sweep
                        && !dirty.iter().any(|changed| {
                            path.starts_with(changed)
                                || std::fs::canonicalize(&path)
                                    .unwrap_or_else(|_| path.clone())
                                    .starts_with(changed)
                        })
                    {
                        continue;
                    }
                    let boundary = match agents.completion_boundary(&terminal).await {
                        Some(boundary) => boundary,
                        None => {
                            let Some((session, path)) = agents.observed_transcript(&terminal).await
                            else {
                                continue;
                            };
                            (session, path, String::new(), i64::MAX)
                        }
                    };
                    if Path::new(&boundary.1) != path {
                        continue;
                    }
                    let mut reader = readers.remove(&terminal).unwrap_or_default();
                    let session = boundary.0.clone();
                    let read_path = path.clone();
                    let after = boundary.3;
                    let result = tokio::task::spawn_blocking(move || {
                        let event = reader.read(&read_path, &session, after);
                        (reader, event)
                    })
                    .await;
                    if let Ok((reader, Ok(event))) = result {
                        if let Some((name, at)) = &reader.title {
                            let _ = agents
                                .apply_claude_title(&terminal, &boundary.0, name, *at)
                                .await;
                        }
                        readers.insert(terminal.clone(), reader);
                        if let Some(event) = event {
                            if agents.completion_boundary(&terminal).await.as_ref()
                                == Some(&boundary)
                            {
                                let _ = agents.claude_event(&terminal, &event).await;
                            }
                        }
                    }
                }
            }
        });
        Ok(this)
    }
    pub fn observe(&self, terminal: &str, path: PathBuf) -> Result<()> {
        let mut entries = self.entries.lock().unwrap();
        let parent = path.parent().ok_or("transcript parent")?;
        if !entries.values().any(|p| p.parent() == Some(parent)) {
            let _ = self
                .watcher
                .lock()
                .unwrap()
                .watch(parent, RecursiveMode::NonRecursive);
        }
        entries.insert(terminal.into(), path.clone());
        drop(entries);
        self.dirty.lock().unwrap().insert(path);
        self.wake.notify_one();
        Ok(())
    }
    pub fn remove(&self, terminal: &str) {
        let mut entries = self.entries.lock().unwrap();
        if let Some(path) = entries.remove(terminal) {
            if !entries.values().any(|p| p.parent() == path.parent()) {
                if let Some(parent) = path.parent() {
                    let _ = self.watcher.lock().unwrap().unwatch(parent);
                }
            }
        }
    }
    pub fn close(&self) {
        self.stop.notify_one();
    }
}

pub fn activity_arguments(binary: &Path, provider: &str) -> Vec<String> {
    if provider == "shell" {
        return vec![];
    }
    let command = format!(
        "'{}' activity-hook",
        binary.to_string_lossy().replace('\'', "'\\''")
    );
    let mut hooks = serde_json::Map::new();
    for name in [
        "SessionStart",
        "SessionEnd",
        "UserPromptSubmit",
        "PreToolUse",
        "PermissionRequest",
        "PostToolUse",
        "Stop",
        "PreCompact",
        "PostToolUseFailure",
        "Notification",
        "StopFailure",
        "Elicitation",
        "ElicitationResult",
    ] {
        hooks.insert(
            name.into(),
            json!([{"hooks":[{"type":"command","command":command,"timeout":10}]}]),
        );
    }
    vec!["--settings".into(), json!({"hooks":hooks}).to_string()]
}
/// Short-lived native hook helper: stdout stays empty, and failures never change
/// the provider's tool decision. Only observational fields cross the private UDS.
pub fn activity_hook() -> Result<()> {
    let observed = now();
    let mut input = Vec::new();
    std::io::stdin()
        .take(1024 * 1024 + 1)
        .read_to_end(&mut input)
        .map_err(|e| e.to_string())?;
    if input.len() > 1024 * 1024 {
        return Ok(());
    }
    let payload: Value = serde_json::from_slice(&input).map_err(|e| e.to_string())?;
    let mut event = json!({"observed_at":observed.to_string()});
    for key in [
        "hook_event_name",
        "session_id",
        "transcript_path",
        "agent_id",
        "turn_id",
        "tool_name",
        "tool_use_id",
        "source",
        "notification_type",
    ] {
        if let Some(value) = payload[key].as_str().filter(|v| v.len() <= 4096) {
            event[key] = json!(value);
        }
    }
    if let Some(text) = payload["last_assistant_message"].as_str() {
        event["last_assistant_message"] = json!(tail(text, 8000));
        if let Some(path) = payload["transcript_path"].as_str() {
            if let Ok(mut file) = File::open(path) {
                if let Ok(metadata) = file.metadata() {
                    let start = metadata.len().saturating_sub(256 * 1024);
                    let _ = file.seek(SeekFrom::Start(start));
                    let mut bytes = Vec::new();
                    let _ = file.take(256 * 1024).read_to_end(&mut bytes);
                    let rows: Vec<Value> = String::from_utf8_lossy(&bytes)
                        .lines()
                        .filter_map(|line| serde_json::from_str(line).ok())
                        .filter(|v: &Value| {
                            v["sessionId"] == payload["session_id"] && v["isSidechain"] != true
                        })
                        .collect();
                    if let Some(boundary) = rows.iter().rposition(|r| {
                        r["type"] == "user"
                            && (r["message"]["content"].is_string()
                                || r["message"]["content"]
                                    .as_array()
                                    .is_some_and(|b| b.iter().any(|b| b["type"] == "text")))
                    }) {
                        for row in rows[boundary..].iter().rev() {
                            if row["type"] == "assistant"
                                && row["message"]["content"].as_array().is_some_and(|blocks| {
                                    blocks
                                        .iter()
                                        .any(|b| b["type"] == "text" && b["text"] == text)
                                })
                            {
                                event["assistant_timestamp"] = row["timestamp"].clone();
                                break;
                            }
                        }
                    }
                }
            }
        }
    }
    while event.to_string().len() > 16000 {
        let Some(text) = event["last_assistant_message"].as_str() else {
            return Ok(());
        };
        event["last_assistant_message"] = json!(tail(text, text.chars().count() / 2));
    }
    if let Ok(path) = std::env::var("NEURA_ACTIVITY_SOCKET") {
        let mut socket =
            std::os::unix::net::UnixStream::connect(path).map_err(|e| e.to_string())?;
        socket
            .set_write_timeout(Some(std::time::Duration::from_secs(4)))
            .map_err(|e| e.to_string())?;
        socket
            .write_all(format!("{event}\n").as_bytes())
            .map_err(|e| e.to_string())?;
    }
    Ok(())
}

pub async fn history(path: Option<&str>, cursor: Option<&str>) -> Result<Value> {
    let Some(path) = path else {
        return Ok(json!({"data":[],"nextCursor":null}));
    };
    let path = PathBuf::from(path);
    let cursor = cursor.map(String::from);
    tokio::task::spawn_blocking(move ||{
  let mut file=match File::open(&path){Ok(f)=>f,Err(_)=>return Ok(json!({"data":[],"nextCursor":null}))};let size=file.metadata().map_err(|e|e.to_string())?.len();let end=match cursor{Some(v)=>v.parse::<u64>().map_err(|_|"invalid_cursor")?,None=>size};if end>size{return Err("invalid_cursor".into())}
  let start=end.saturating_sub(2*1024*1024);file.seek(SeekFrom::Start(start)).map_err(|e|e.to_string())?;let mut bytes=vec![0;(end-start) as usize];file.read_exact(&mut bytes).map_err(|e|e.to_string())?;
  let first=if start==0{0}else{bytes.iter().position(|b|*b==b'\n').map(|i|i+1).unwrap_or(0)};let mut records=Vec::new();let mut offset=first;
  for line in bytes[first..].split(|b|*b==b'\n'){if let Ok(v)=serde_json::from_slice::<Value>(line){if v["uuid"].is_string()&&v["isSidechain"]!=true&&v["message"].is_object(){records.push((start+offset as u64,v));}}offset+=line.len()+1;}
  let selected=records.len().saturating_sub(20);let next=if records.len()>20{records[selected].0}else if start==0{0}else{start+first as u64};
  let mut data:Vec<_>=records[selected..].iter().rev().map(|(_,v)|{let blocks=v["message"]["content"].as_array().cloned().unwrap_or_else(||vec![json!({"type":"text","text":v["message"]["content"]})]);let items:Vec<_>=blocks.iter().enumerate().map(|(i,b)|json!({"id":format!("{}:{i}",v["uuid"].as_str().unwrap()),"type":if b["type"]=="text"{if v["type"]=="user"{json!("userMessage")}else{json!("agentMessage")}}else{b["type"].clone()},"text":if b["type"]=="text"{b["text"].clone()}else{json!(b.to_string())}})).collect();json!({"id":v["uuid"],"status":"completed","items":items})}).collect();
  if data.is_empty()&&end>0{data.push(json!({"id":format!("transcript-window:{end}"),"status":"completed","items":[{"id":format!("transcript-window:{end}"),"type":"historyNotice","text":"No displayable records in this bounded window. Original evidence remains in the transcript."}]}));}
  Ok(json!({"data":data,"nextCursor":if next>0&&next<end{Some(next.to_string())}else if start>0{Some(start.to_string())}else{None}}))
 }).await.map_err(|e|e.to_string())?
}
