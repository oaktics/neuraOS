//! In-memory browser bridge. Page contents and form values are never persisted.
//! HTTP callers must authenticate the daemon token and independently validate the
//! terminal-scoped browser credential before invoking `call`.
use crate::error::ApiError;
use serde::Deserialize;
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::{sync::oneshot, task::AbortHandle, time::Instant};
use uuid::Uuid;

fn error(code: &str, status: u16) -> ApiError {
    ApiError::new(
        code,
        "Browser operation stopped. Read the current state before retrying.",
        status,
    )
}
fn invalid() -> ApiError {
    error("invalid_request", 400)
}
fn uuid(value: &str) -> Result<(), ApiError> {
    if crate::contracts::valid_uuid(value) {
        Ok(())
    } else {
        Err(invalid())
    }
}
fn field<'a>(v: &'a Value, key: &str) -> &'a str {
    v.get(key).and_then(Value::as_str).unwrap_or("")
}
fn find<'a>(snapshot: &'a Value, table: &str, id: &str) -> Option<&'a Value> {
    snapshot
        .get(table)?
        .as_array()?
        .iter()
        .find(|v| field(v, "id") == id)
}
#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Tab {
    workspace_id: String,
    tab_id: String,
    project_id: String,
    url: String,
    title: String,
    selected: bool,
    loading: bool,
    enabled: bool,
}
impl Tab {
    fn value(&self) -> Value {
        json!({"workspaceId":self.workspace_id,"tabId":self.tab_id,"projectId":self.project_id,"url":self.url,"title":self.title,"selected":self.selected,"loading":self.loading,"enabled":self.enabled})
    }
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Poll {
    native_id: String,
    #[serde(default)]
    stream: bool,
    tabs: Vec<Tab>,
    results: Vec<NativeResult>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct NativeResult {
    id: String,
    result: Option<Value>,
    error: Option<String>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Call {
    terminal_id: String,
    command: Value,
}
struct Pending {
    command: Value,
    project: String,
    terminal: String,
    deadline: u64,
    sent: bool,
    cancelled: bool,
    sender: Option<oneshot::Sender<Result<Value, ApiError>>>,
    timer: Option<AbortHandle>,
}
struct State {
    instance: String,
    native: String,
    lease_until: Option<Instant>,
    lease_timer: Option<AbortHandle>,
    generation: u64,
    tabs: Vec<Tab>,
    pending: HashMap<String, Pending>,
    closed: bool,
}
#[derive(Clone)]
pub struct BrowserBroker {
    state: Arc<Mutex<State>>,
    notify: Arc<dyn Fn() + Send + Sync>,
}
impl BrowserBroker {
    pub fn new(notify: impl Fn() + Send + Sync + 'static) -> Self {
        Self {
            state: Arc::new(Mutex::new(State {
                instance: Uuid::new_v4().to_string(),
                native: String::new(),
                lease_until: None,
                lease_timer: None,
                generation: 0,
                tabs: vec![],
                pending: HashMap::new(),
                closed: false,
            })),
            notify: Arc::new(notify),
        }
    }
    pub fn shutdown(&self) {
        let mut s = self.state.lock().unwrap();
        s.closed = true;
        if let Some(t) = s.lease_timer.take() {
            t.abort();
        }
        let ids: Vec<_> = s.pending.keys().cloned().collect();
        for id in ids {
            settle(&mut s, &id, None, Some("browser_disconnected"));
        }
        s.pending.clear();
        s.tabs.clear();
    }
    pub fn poll(&self, body: Value, snapshot: &Value) -> Result<Value, ApiError> {
        let b: Poll = serde_json::from_value(body).map_err(|_| invalid())?;
        uuid(&b.native_id)?;
        if b.tabs.len() > 500 || b.results.len() > 32 {
            return Err(invalid());
        }
        for t in &b.tabs {
            uuid(&t.workspace_id)?;
            uuid(&t.tab_id)?;
            uuid(&t.project_id)?;
            if t.url.encode_utf16().count() > 8192 || t.title.encode_utf16().count() > 2048 {
                return Err(invalid());
            }
        }
        for r in &b.results {
            uuid(&r.id)?;
            if r.error.as_ref().is_some_and(|e| e.len() > 100) {
                return Err(invalid());
            }
        }
        let mut s = self.state.lock().unwrap();
        if s.closed {
            return Err(error("browser_disconnected", 503));
        }
        let live = s.lease_until.is_some_and(|t| t > Instant::now());
        if !s.native.is_empty() && s.native != b.native_id && live {
            return Err(error("browser_native_busy", 409));
        }
        if s.native != b.native_id {
            let ids: Vec<_> = s.pending.keys().cloned().collect();
            for id in ids {
                settle(&mut s, &id, None, Some("browser_restarted"));
            }
            s.pending.clear();
        }
        s.native = b.native_id;
        let lease = Duration::from_secs(if b.stream { 45 } else { 3 });
        s.lease_until = Some(Instant::now() + lease);
        s.generation += 1;
        let generation = s.generation;
        if let Some(t) = s.lease_timer.take() {
            t.abort();
        }
        let weak = Arc::downgrade(&self.state);
        let notify = self.notify.clone();
        s.lease_timer = Some(
            tokio::spawn(async move {
                tokio::time::sleep(lease).await;
                if let Some(state) = weak.upgrade() {
                    let mut s = state.lock().unwrap();
                    if s.generation != generation {
                        return;
                    }
                    s.tabs.clear();
                    s.lease_until = None;
                    let ids: Vec<_> = s.pending.keys().cloned().collect();
                    for id in ids {
                        settle(&mut s, &id, None, Some("browser_disconnected"));
                    }
                    drop(s);
                    notify();
                }
            })
            .abort_handle(),
        );
        s.tabs = b
            .tabs
            .into_iter()
            .filter(|t| {
                find(snapshot, "workspaces", &t.workspace_id)
                    .is_some_and(|w| field(w, "projectId") == t.project_id)
            })
            .collect();
        for r in b.results {
            settle(&mut s, &r.id, r.result, r.error.as_deref());
            s.pending.remove(&r.id);
        }
        let invalidated: Vec<_> = s
            .pending
            .iter()
            .filter_map(|(id, p)| {
                let caller = find(snapshot, "terminals", &p.terminal);
                let active = caller.is_some_and(|c| {
                    field(c, "status") == "running"
                        && find(snapshot, "workspaces", field(c, "workspaceId"))
                            .is_some_and(|w| field(w, "projectId") == p.project)
                });
                let reason = if !active {
                    Some("browser_caller_inactive")
                } else {
                    match s.tabs.iter().find(|t| {
                        t.workspace_id == field(&p.command, "workspaceId")
                            && t.tab_id == field(&p.command, "tabId")
                    }) {
                        None => Some("browser_tab_closed"),
                        Some(t) if !t.enabled && field(&p.command, "action") != "stop" => {
                            Some("browser_disabled")
                        }
                        _ => None,
                    }
                };
                reason.map(|reason| (id.clone(), reason))
            })
            .collect();
        for (id, reason) in invalidated {
            settle(&mut s, &id, None, Some(reason));
        }
        let now = millis();
        let requests:Vec<_>=s.pending.iter_mut().filter_map(|(id,p)|{
            if p.sent || p.cancelled || p.deadline<=now{return None;}
            p.sent=true;
            Some(json!({"id":id,"deadline":p.deadline,"projectId":p.project,"terminalId":p.terminal,"command":p.command}))
        }).collect();
        let cancel_ids: Vec<_> = s
            .pending
            .iter()
            .filter(|(_, p)| p.cancelled)
            .map(|(id, _)| id.clone())
            .collect();
        Ok(json!({"instanceId":s.instance,"requests":requests,"cancelIds":cancel_ids}))
    }
    pub async fn call(
        &self,
        body: Value,
        snapshot: &Value,
        credential_verified: bool,
    ) -> Result<Value, ApiError> {
        let b: Call = serde_json::from_value(body).map_err(|_| invalid())?;
        uuid(&b.terminal_id)?;
        let command = validate_command(b.command)?;
        if !credential_verified {
            return Err(error("browser_caller_unauthorized", 403));
        }
        let caller = find(snapshot, "terminals", &b.terminal_id)
            .ok_or_else(|| error("browser_caller_missing", 404))?;
        if field(caller, "status") != "running"
            || !["codex", "claude"].contains(&field(caller, "provider"))
        {
            return Err(error("browser_caller_inactive", 403));
        }
        let workspace = find(snapshot, "workspaces", field(caller, "workspaceId"))
            .ok_or_else(|| error("workspace_missing", 404))?;
        let project = field(workspace, "projectId");
        if command.get("workspaceId").is_some() {
            let target = find(snapshot, "workspaces", field(&command, "workspaceId"))
                .ok_or_else(|| error("workspace_missing", 404))?;
            if field(target, "projectId") != project {
                return Err(error("browser_forbidden", 403));
            }
        }
        let (id, receiver) = {
            let mut s = self.state.lock().unwrap();
            if s.closed || !s.lease_until.is_some_and(|t| t > Instant::now()) {
                return Err(error("browser_disconnected", 503));
            }
            let action = field(&command, "action");
            if action == "list" {
                let tabs: Vec<_> = s
                    .tabs
                    .iter()
                    .filter(|t| {
                        t.project_id == project
                            && (command.get("workspaceId").is_none()
                                || t.workspace_id == field(&command, "workspaceId"))
                    })
                    .map(Tab::value)
                    .collect();
                return Ok(json!({"currentWorkspaceId":field(caller,"workspaceId"),"tabs":tabs}));
            }
            let tab = s
                .tabs
                .iter()
                .find(|t| {
                    t.workspace_id == field(&command, "workspaceId")
                        && t.tab_id == field(&command, "tabId")
                })
                .ok_or_else(|| error("browser_tab_closed", 404))?;
            if tab.project_id != project {
                return Err(error("browser_forbidden", 403));
            }
            if !tab.enabled && action != "stop" {
                return Err(error("browser_disabled", 409));
            }
            let matching: Vec<_> = s
                .pending
                .iter()
                .filter(|(_, p)| {
                    field(&p.command, "workspaceId") == field(&command, "workspaceId")
                        && field(&p.command, "tabId") == field(&command, "tabId")
                })
                .map(|(id, _)| id.clone())
                .collect();
            if action == "stop" {
                for id in matching {
                    settle(&mut s, &id, None, Some("browser_cancelled"));
                }
            } else if !matching.is_empty() {
                return Err(error("browser_busy", 409));
            }
            // No global concurrency cap: independent tabs do not block one another.
            let id = Uuid::new_v4().to_string();
            let (sender, receiver) = oneshot::channel();
            let budget = if action == "wait" {
                command["timeoutMs"].as_u64().unwrap() + 2000
            } else {
                30000
            };
            let weak = Arc::downgrade(&self.state);
            let notify = self.notify.clone();
            let timeout_id = id.clone();
            let timer = tokio::spawn(async move {
                tokio::time::sleep(Duration::from_millis(budget)).await;
                if let Some(state) = weak.upgrade() {
                    let mut s = state.lock().unwrap();
                    // Do not abort the timer that is currently settling this request.
                    if let Some(p) = s.pending.get_mut(&timeout_id) {
                        p.timer = None;
                    }
                    settle(&mut s, &timeout_id, None, Some("browser_timeout"));
                    drop(s);
                    notify();
                }
            })
            .abort_handle();
            s.pending.insert(
                id.clone(),
                Pending {
                    command,
                    project: project.into(),
                    terminal: b.terminal_id,
                    deadline: millis() + budget,
                    sent: false,
                    cancelled: false,
                    sender: Some(sender),
                    timer: Some(timer),
                },
            );
            (id, receiver)
        };
        let guard = CallGuard {
            broker: self.clone(),
            id,
        };
        (self.notify)();
        let result = receiver
            .await
            .unwrap_or_else(|_| Err(error("browser_disconnected", 503)));
        drop(guard);
        result
    }
}
struct CallGuard {
    broker: BrowserBroker,
    id: String,
}
impl Drop for CallGuard {
    fn drop(&mut self) {
        let mut s = self.broker.state.lock().unwrap();
        let active = s.pending.get(&self.id).is_some_and(|p| p.sender.is_some());
        if active {
            settle(&mut s, &self.id, None, Some("browser_cancelled"));
        }
        drop(s);
        if active {
            (self.broker.notify)();
        }
    }
}
fn settle(s: &mut State, id: &str, result: Option<Value>, failure: Option<&str>) {
    let Some(p) = s.pending.get_mut(id) else {
        return;
    };
    let Some(sender) = p.sender.take() else {
        return;
    };
    if let Some(t) = p.timer.take() {
        t.abort();
    }
    if let Some(code) = failure {
        p.cancelled = true;
        let sent = p.sent;
        let _ = sender.send(Err(error(code, 409)));
        // Dispatched operations retain their tab lock until native acknowledges.
        if !sent {
            s.pending.remove(id);
        }
    } else {
        let _=sender.send(Ok(json!({"workspaceId":p.command["workspaceId"],"tabId":p.command["tabId"],"result":result.unwrap_or(Value::Null)})));
    }
}
fn millis() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}
fn validate_command(mut c: Value) -> Result<Value, ApiError> {
    let obj = c.as_object().ok_or_else(invalid)?;
    let action = field(&c, "action");
    let mut allowed = vec!["action", "workspaceId"];
    if action != "list" {
        allowed.push("tabId");
    }
    match action {
        "list" | "snapshot" | "screenshot" | "stop" => {}
        "navigate" => allowed.push("url"),
        "click" => allowed.push("ref"),
        "fill" => allowed.extend(["ref", "text"]),
        "key" => allowed.extend(["ref", "key"]),
        "scroll" => allowed.extend(["ref", "x", "y"]),
        "wait" => allowed.extend(["text", "timeoutMs"]),
        _ => return Err(invalid()),
    }
    if obj.keys().any(|k| !allowed.contains(&k.as_str())) {
        return Err(invalid());
    }
    if action != "list" || obj.contains_key("workspaceId") {
        uuid(field(&c, "workspaceId"))?;
    }
    if action != "list" {
        uuid(field(&c, "tabId"))?;
    }
    let bounded = |key: &str, min: usize, max: usize| -> Result<(), ApiError> {
        let n = c
            .get(key)
            .and_then(Value::as_str)
            .ok_or_else(invalid)?
            .encode_utf16()
            .count();
        if n < min || n > max {
            Err(invalid())
        } else {
            Ok(())
        }
    };
    if allowed.contains(&"ref") {
        bounded("ref", 0, 100)?;
    }
    match action {
        "navigate" => {
            bounded("url", 0, 8192)?;
            let v = field(&c, "url");
            if v != "about:blank" {
                let u = url::Url::parse(v).map_err(|_| invalid())?;
                if !["http", "https"].contains(&u.scheme())
                    || !u.username().is_empty()
                    || u.password().is_some()
                {
                    return Err(invalid());
                }
            }
        }
        "fill" => bounded("text", 0, 10000)?,
        "key" => {
            if ![
                "Enter",
                "Tab",
                "Escape",
                "Backspace",
                "ArrowUp",
                "ArrowDown",
                "ArrowLeft",
                "ArrowRight",
            ]
            .contains(&field(&c, "key"))
            {
                return Err(invalid());
            }
        }
        "scroll" => {
            for k in ["x", "y"] {
                if !c[k]
                    .as_f64()
                    .is_some_and(|n| n.is_finite() && (-10000.0..=10000.0).contains(&n))
                {
                    return Err(invalid());
                }
            }
        }
        "wait" => {
            bounded("text", 1, 1000)?;
            let n = match c.get("timeoutMs") {
                None => 5000,
                Some(v) => v.as_u64().ok_or_else(invalid)?,
            };
            if !(100..=15000).contains(&n) {
                return Err(invalid());
            }
            c["timeoutMs"] = json!(n);
        }
        _ => {}
    }
    Ok(c)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> (BrowserBroker, Value, Value, Value) {
        let w = Uuid::new_v4().to_string();
        let p = Uuid::new_v4().to_string();
        let t = Uuid::new_v4().to_string();
        let tab = Uuid::new_v4().to_string();
        let snapshot = json!({"workspaces":[{"id":w,"projectId":p}],"terminals":[{"id":t,"workspaceId":w,"provider":"codex","status":"running"}]});
        let poll = json!({"nativeId":Uuid::new_v4().to_string(),"stream":true,"tabs":[{"workspaceId":w,"projectId":p,"tabId":tab,"url":"https://example.test","title":"test","selected":true,"enabled":true,"loading":false}],"results":[]});
        let call =
            json!({"terminalId":t,"command":{"action":"snapshot","workspaceId":w,"tabId":tab}});
        let b = BrowserBroker::new(|| {});
        b.poll(poll.clone(), &snapshot).unwrap();
        (b, snapshot, poll, call)
    }
    async fn dispatch(
        b: &BrowserBroker,
        snapshot: &Value,
        poll: &Value,
        call: &Value,
    ) -> (tokio::task::JoinHandle<Result<Value, ApiError>>, Value) {
        let bb = b.clone();
        let ss = snapshot.clone();
        let cc = call.clone();
        let task = tokio::spawn(async move { bb.call(cc, &ss, true).await });
        tokio::task::yield_now().await;
        let result = b.poll(poll.clone(), snapshot).unwrap();
        assert_eq!(result["requests"].as_array().unwrap().len(), 1);
        (task, result["requests"][0].clone())
    }
    #[tokio::test]
    async fn scopes_credentials_and_native_ownership() {
        let (b, s, p, c) = fixture();
        assert_eq!(
            b.call(c.clone(), &s, false).await.unwrap_err().error,
            "browser_caller_unauthorized"
        );
        let mut wrong = c.clone();
        wrong["command"]["workspaceId"] = json!(Uuid::new_v4().to_string());
        assert_eq!(
            b.call(wrong, &s, true).await.unwrap_err().error,
            "workspace_missing"
        );
        let mut other = p.clone();
        other["nativeId"] = json!(Uuid::new_v4().to_string());
        assert_eq!(b.poll(other, &s).unwrap_err().error, "browser_native_busy");
        let mut forged = p.clone();
        forged["tabs"][0]["projectId"] = json!(Uuid::new_v4().to_string());
        b.poll(forged, &s).unwrap();
        assert_eq!(
            b.call(c, &s, true).await.unwrap_err().error,
            "browser_tab_closed"
        );
        b.shutdown();
    }
    #[tokio::test]
    async fn results_release_locks_and_errors_preserve_codes() {
        let (b, s, mut p, c) = fixture();
        let (task, r) = dispatch(&b, &s, &p, &c).await;
        assert_eq!(
            b.call(c.clone(), &s, true).await.unwrap_err().error,
            "browser_busy"
        );
        p["results"] = json!([{"id":r["id"],"error":"browser_stale_ref"}]);
        b.poll(p.clone(), &s).unwrap();
        assert_eq!(task.await.unwrap().unwrap_err().error, "browser_stale_ref");
        p["results"] = json!([]);
        let (task, r) = dispatch(&b, &s, &p, &c).await;
        p["results"] = json!([{"id":r["id"],"result":{"text":"ok"}}]);
        b.poll(p, &s).unwrap();
        assert_eq!(task.await.unwrap().unwrap()["result"]["text"], "ok");
        b.shutdown();
    }
    #[tokio::test(start_paused = true)]
    async fn timeout_quarantines_until_acknowledged() {
        let (b, s, mut p, mut c) = fixture();
        c["command"]["action"] = json!("wait");
        c["command"]["text"] = json!("missing");
        c["command"]["timeoutMs"] = json!(100);
        let (task, r) = dispatch(&b, &s, &p, &c).await;
        tokio::time::advance(Duration::from_millis(2101)).await;
        assert_eq!(task.await.unwrap().unwrap_err().error, "browser_timeout");
        let update = b.poll(p.clone(), &s).unwrap();
        assert_eq!(update["cancelIds"][0], r["id"]);
        assert_eq!(update["requests"], json!([]));
        assert_eq!(
            b.call(c.clone(), &s, true).await.unwrap_err().error,
            "browser_busy"
        );
        p["results"] = json!([{"id":r["id"],"error":"browser_cancelled"}]);
        b.poll(p.clone(), &s).unwrap();
        p["results"] = json!([]);
        let (task, _) = dispatch(&b, &s, &p, &c).await;
        b.shutdown();
        assert_eq!(
            task.await.unwrap().unwrap_err().error,
            "browser_disconnected"
        );
    }
    #[tokio::test]
    async fn abandoned_http_call_cancels_without_releasing_dispatched_lock() {
        let (b, s, p, c) = fixture();
        let (task, r) = dispatch(&b, &s, &p, &c).await;
        task.abort();
        let _ = task.await;
        let update = b.poll(p, &s).unwrap();
        assert_eq!(update["cancelIds"][0], r["id"]);
        assert_eq!(b.call(c, &s, true).await.unwrap_err().error, "browser_busy");
        b.shutdown();
    }
    #[tokio::test(start_paused = true)]
    async fn lease_expiry_cancels_and_new_native_resets_registry() {
        let (b, s, mut p, c) = fixture();
        let (task, _) = dispatch(&b, &s, &p, &c).await;
        // Keep the call's 30s budget beyond a legacy 3s lease.
        p["stream"] = json!(false);
        b.poll(p.clone(), &s).unwrap();
        tokio::time::advance(Duration::from_secs(4)).await;
        assert_eq!(
            task.await.unwrap().unwrap_err().error,
            "browser_disconnected"
        );
        assert_eq!(
            b.call(c.clone(), &s, true).await.unwrap_err().error,
            "browser_disconnected"
        );
        p["nativeId"] = json!(Uuid::new_v4().to_string());
        b.poll(p.clone(), &s).unwrap();
        let (task, _) = dispatch(&b, &s, &p, &c).await;
        b.shutdown();
        let _ = task.await;
    }
    #[test]
    fn rejects_unbounded_or_arbitrary_commands() {
        assert!(validate_command(json!({"action":"evaluate","script":"document.cookie"})).is_err());
        assert!(validate_command(json!({"action":"list","extra":true})).is_err());
        let w = Uuid::new_v4().to_string();
        let t = Uuid::new_v4().to_string();
        for url in [
            "file:///etc/passwd",
            "javascript:alert(1)",
            "https://user:secret@example.test",
        ] {
            assert!(validate_command(
                json!({"action":"navigate","workspaceId":w,"tabId":t,"url":url})
            )
            .is_err());
        }
    }
    #[tokio::test]
    async fn independent_tabs_exceed_old_global_request_cap() {
        let (b, s, mut p, c) = fixture();
        let template = p["tabs"][0].clone();
        let mut tabs = Vec::new();
        let mut tasks = Vec::new();
        for _ in 0..64 {
            let mut tab = template.clone();
            tab["tabId"] = json!(Uuid::new_v4().to_string());
            tabs.push(tab);
        }
        p["tabs"] = json!(tabs);
        b.poll(p.clone(), &s).unwrap();
        for tab in &tabs {
            let bb = b.clone();
            let ss = s.clone();
            let mut cc = c.clone();
            cc["command"]["tabId"] = tab["tabId"].clone();
            tasks.push(tokio::spawn(async move { bb.call(cc, &ss, true).await }));
        }
        tokio::time::timeout(Duration::from_secs(1), async {
            while b.state.lock().unwrap().pending.len() < 64 {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        let update = b.poll(p.clone(), &s).unwrap();
        let requests = update["requests"].as_array().unwrap();
        assert_eq!(requests.len(), 64);
        for batch in requests.chunks(32) {
            p["results"] = json!(batch
                .iter()
                .map(|r| json!({"id":r["id"],"result":{"ok":true}}))
                .collect::<Vec<_>>());
            b.poll(p.clone(), &s).unwrap();
        }
        for task in tasks {
            assert_eq!(task.await.unwrap().unwrap()["result"]["ok"], true);
        }
        b.shutdown();
    }
}
