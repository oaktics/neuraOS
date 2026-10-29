use crate::diagnostics::{Diagnostics, Phase};
use crate::workspace::text;
use crate::{
    browser::BrowserBroker, contracts, error::ApiError, events::Change, github::GitHub,
    providers::ProviderService, pty::PtyRuntime, store::StoreHandle, usage::ProviderUsageService,
    workspace as work,
};
use axum::{
    extract::{
        ws::{Message, WebSocket},
        DefaultBodyLimit, Path, Query, State, WebSocketUpgrade,
    },
    http::HeaderMap,
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use std::{
    collections::{HashMap, HashSet},
    path::PathBuf,
    sync::{Arc, Weak},
    time::Duration,
};
use tokio::sync::{broadcast, Mutex};
use uuid::Uuid;
const FEATURES: &[&str] = &[
    "agent.supervision",
    "agent.reports",
    "workspace.cleanup",
    "project.remove",
    "github",
    "workspace.delete",
    "workspace.delete.discard",
    "workspace.delete.stop-terminals",
    "terminal.multiple",
    "provider.usage",
    "terminal.activity",
    "terminal.notifications",
    "github.checks",
    "workspace.remote-default",
    "project.worktree-startup",
    "project.worktree-setup",
    "project.folderless",
    "workspace.from-pr",
    "project.default-providers",
    "agent.claude-channels",
    "state.stream",
];
struct SetupJob {
    cancel: tokio::sync::watch::Sender<bool>,
    task: tokio::task::JoinHandle<Result<(), ApiError>>,
}
pub struct AppState {
    diagnostics: Diagnostics,
    pub store: StoreHandle,
    pub events: broadcast::Sender<Change>,
    pub token: String,
    pub pty: PtyRuntime,
    pub providers: Arc<ProviderService>,
    pub browser: BrowserBroker,
    pub github: GitHub,
    pub usage: ProviderUsageService,
    pub data_dir: PathBuf,
    operations: Mutex<HashMap<String, Weak<Mutex<()>>>>,
    mutation: crate::mutation::MutationLocks,
    owners: Mutex<HashMap<String, (String, tokio::time::Instant)>>,
    browser_poll_gate: Mutex<()>,
    setups: Mutex<HashMap<String, SetupJob>>,
    pub epoch: String,
    pub closing: tokio::sync::watch::Sender<bool>,
}
fn provider_error(e: String) -> ApiError {
    let code = e.split(':').next().unwrap_or("provider_failed");
    ApiError::new(code, "CLIの状態を確認してください。", 409)
}
fn invalid() -> ApiError {
    ApiError::new("invalid_request", "要求の形式が正しくありません。", 400)
}
fn id(id: &str) -> Result<(), ApiError> {
    if contracts::valid_uuid(id) {
        Ok(())
    } else {
        Err(invalid())
    }
}
impl AppState {
    pub async fn new(
        data_dir: PathBuf,
        token: String,
        endpoint: String,
    ) -> Result<Arc<Self>, ApiError> {
        let (events, _) = broadcast::channel(256);
        let store = StoreHandle::open(&data_dir.join("developer.sqlite"), events.clone()).await?;
        let pty = PtyRuntime::new_supervised(store.clone())?;
        let providers = ProviderService::new(
            store.clone(),
            pty.clone(),
            endpoint,
            data_dir.join("daemon-token").to_string_lossy().into_owned(),
        )
        .await
        .map_err(provider_error)?;
        let notify = events.clone();
        let browser = BrowserBroker::new(move || {
            let _ = notify.send(Change {
                browser: true,
                ..Default::default()
            });
        });
        let diagnostics =
            Diagnostics::new(data_dir.join("diagnostics")).map_err(|_| ApiError::storage())?;
        diagnostics.record(Phase::Start, None, None, None);
        let this = Arc::new(Self {
            diagnostics,
            store,
            events,
            token,
            pty,
            providers,
            browser,
            github: GitHub::new(),
            usage: ProviderUsageService::new(),
            data_dir,
            operations: Mutex::new(HashMap::new()),
            mutation: crate::mutation::MutationLocks::default(),
            owners: Mutex::new(HashMap::new()),
            browser_poll_gate: Mutex::new(()),
            setups: Mutex::new(HashMap::new()),
            epoch: Uuid::new_v4().to_string(),
            closing: tokio::sync::watch::channel(false).0,
        });
        for mut w in this.store.list("workspaces").await? {
            if w["setup"]["status"] == "running" {
                w["setup"]["status"] = json!("failed");
                w["setup"]["error"] = json!("Daemonが終了したためセットアップを中断しました。");
                this.store.put("workspaces", w, None).await?;
            }
        }
        let weak = Arc::downgrade(&this);
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(Duration::from_secs(15));
            tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            loop {
                tick.tick().await;
                let Some(s) = weak.upgrade() else {
                    break;
                };
                let _ = s.reconcile().await;
            }
        });
        Ok(this)
    }
    pub async fn entity(&self, table: &str, key: &str) -> Result<Value, ApiError> {
        id(key)?;
        self.store.get(table, key).await?.ok_or_else(|| {
            ApiError::new(
                if table == "workspaces" {
                    "workspace_missing"
                } else {
                    "project_missing"
                },
                "対象がありません。",
                404,
            )
        })
    }
    pub async fn reconcile(&self) -> Result<(), ApiError> {
        for candidate in self.store.list("projects").await? {
            if candidate["isGit"] != false || candidate["folderless"] == true {
                continue;
            }
            let path = text(&candidate, "path")?;
            if !tokio::fs::try_exists(std::path::Path::new(path).join(".git"))
                .await
                .unwrap_or(false)
            {
                continue;
            }
            let Ok((root, true)) = work::project_folder(path).await else {
                continue;
            };
            if root != path {
                continue;
            }
            let branch = work::git(&root, &["branch", "--show-current"]).await?;
            let pid = text(&candidate, "id")?;
            let current = self
                .store
                .update("projects", pid, |p| {
                    if p["path"] == path && p["folderless"] != true {
                        p["isGit"] = json!(true);
                    }
                })
                .await?;
            if !current.is_some_and(|p| p["path"] == path && p["isGit"] == true) {
                continue;
            }
            for w in self.store.list("workspaces").await? {
                if w["projectId"] == pid && w["path"] == root && w["kind"] == "folder" {
                    self.store
                        .update("workspaces", text(&w, "id")?, |w| {
                            if w["projectId"] == pid && w["path"] == root && w["kind"] == "folder" {
                                w["kind"] = json!("root");
                                w["branch"] = json!(if branch.trim().is_empty() {
                                    "(detached)"
                                } else {
                                    branch.trim()
                                });
                            }
                        })
                        .await?;
                }
            }
        }
        Ok(())
    }
    pub async fn snapshot(&self) -> Result<Value, ApiError> {
        self.pty.check_healthy()?;
        let mut s = self
            .store
            .call(
                "state",
                json!({"hostName":std::env::var("NEURA_HOST_NAME").unwrap_or("このMac".into())}),
            )
            .await?;
        s["features"] = json!(FEATURES);
        s["runtime"] = json!("rust");
        s["daemonInstanceId"] = json!(self.epoch);
        Ok(s)
    }
    pub async fn shutdown(&self) -> Result<(), ApiError> {
        self.closing.send_replace(true);
        self.browser.shutdown();
        let mut failed = false;
        let jobs: Vec<_> = self
            .setups
            .lock()
            .await
            .drain()
            .map(|(_, job)| job)
            .collect();
        for job in &jobs {
            job.cancel.send_replace(true);
        }
        for job in jobs {
            if !matches!(
                tokio::time::timeout(Duration::from_secs(12), job.task).await,
                Ok(Ok(Ok(())))
            ) {
                failed = true;
            }
        }
        if self.providers.shutdown().await.is_err() {
            failed = true;
        }
        if self.pty.shutdown().await.is_err() {
            failed = true;
        }
        self.usage.close().await;
        if self.store.call("barrier", json!({})).await.is_err() {
            failed = true;
        }
        if failed {
            self.diagnostics.record(Phase::Failure, None, None, None);
        }
        self.diagnostics.record(Phase::End, None, None, None);
        self.diagnostics.flush().await;
        neura_native_core::performance::flush().await;
        if failed {
            Err(ApiError::new(
                "shutdown_incomplete",
                "所有プロセスまたは保存処理の完了を確認できません。",
                500,
            ))
        } else {
            Ok(())
        }
    }
    async fn claim(&self, id: &str, client: &str) -> Result<(), ApiError> {
        let mut owners = self.owners.lock().await;
        owners.retain(|_, (_, until)| *until > tokio::time::Instant::now());
        if let Some((old, until)) = owners.get(id) {
            if old != client && *until > tokio::time::Instant::now() {
                return Err(ApiError::new(
                    "terminal_busy",
                    "別の画面で操作中です。",
                    409,
                ));
            }
        }
        owners.insert(
            id.into(),
            (
                client.into(),
                tokio::time::Instant::now() + Duration::from_secs(15),
            ),
        );
        Ok(())
    }
    pub async fn open(
        self: &Arc<Self>,
        workspace: Value,
        provider: &str,
        resume: bool,
        options: &Value,
    ) -> Result<Value, ApiError> {
        let terminal = Uuid::new_v4().to_string();
        let mut record = json!({"id":terminal,"workspaceId":workspace["id"],"provider":provider,"status":"running","createdAt":chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis,true),"cols":100,"rows":30});
        if provider != "shell" {
            record["activity"] = json!("unknown");
        }
        self.store.put("terminals", record.clone(), None).await?;
        let launch = self
            .providers
            .prepare(
                &workspace,
                &terminal,
                provider,
                options["resumeId"].as_str().map(String::from),
                options["parentTaskId"].as_str().map(String::from),
                options["prompt"].as_str().map(String::from),
                resume && options["resumeId"].is_null(),
            )
            .await;
        let result=async{let spec=launch.map_err(provider_error)?;record=self.store.get("terminals",&terminal).await?.ok_or_else(ApiError::storage)?;if let Some(agent)=spec.agent_id{loop{let expected=self.store.get("terminals",&terminal).await?.ok_or_else(ApiError::storage)?;let mut updated=expected.clone();if updated["agentId"].is_null(){updated["agentId"]=json!(agent);}if updated["sessionId"].is_null(){updated["sessionId"]=json!(agent);}if updated==expected||self.store.call("compare_put",json!({"table":"terminals","id":terminal,"expected":expected,"value":updated})).await?==true{break;}}}self.store.call("append",json!([{"terminalId":terminal,"data":"","cols":100,"rows":30}])).await?;self.pty.spawn(&terminal,&spec.program,spec.args,text(&workspace,"path")?,spec.env).await?;Ok(self.store.get("terminals",&terminal).await?.ok_or_else(ApiError::storage)?)}.await;
        if result.is_err() {
            let _ = self.providers.close(&terminal).await;
            let _ = self
                .store
                .update("terminals", &terminal, |record| {
                    if record["status"] == "running" {
                        record["status"] = json!("interrupted");
                    }
                })
                .await;
        }
        result
    }
    pub async fn stop_workspace(&self, workspace: &str) -> Result<(), ApiError> {
        for t in self.store.list("terminals").await? {
            if t["workspaceId"] == workspace && t["status"] == "running" {
                let id = text(&t, "id")?;
                self.pty.stop(id).await?;
                self.providers.close(id).await.map_err(provider_error)?;
            }
        }
        let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
        loop {
            let any = self
                .store
                .list("terminals")
                .await?
                .iter()
                .any(|t| t["workspaceId"] == workspace && t["status"] == "running");
            if !any {
                return Ok(());
            }
            if tokio::time::Instant::now() >= deadline {
                return Err(ApiError::new(
                    "terminal_stop_timeout",
                    "ターミナルの終了を確認できません。",
                    409,
                ));
            }
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
    }
}
pub fn router(state: Arc<AppState>) -> Router {
    Router::new()
        .route("/v1/state", get(state_get))
        .route("/v1/stream", get(stream))
        .route("/v1/capabilities", get(capabilities))
        .route("/v1/usage", get(usage))
        .route("/v1/notifications", get(notifications))
        .route("/v1/events", get(events))
        .route("/v1/commands", post(command))
        .route("/v1/agents", get(agents))
        .route("/v1/agents/{id}", get(agent))
        .route("/v1/claude/{id}/{action}", post(channel))
        .route("/v1/terminals/{id}/output", get(output))
        .route("/v1/workspaces/{id}/{action}", get(workspace_read))
        .route("/v1/projects/{id}/{action}", get(project_read))
        .route("/v1/browser/call", post(browser_call))
        .route(
            "/v1/browser/native/poll",
            post(browser_poll).layer(DefaultBodyLimit::max(12 * 1024 * 1024)),
        )
        .layer(DefaultBodyLimit::max(2 * 1024 * 1024))
        .layer(middleware::from_fn_with_state(state.clone(), auth))
        .with_state(state)
}
async fn auth(State(s): State<Arc<AppState>>, req: axum::extract::Request, next: Next) -> Response {
    let h = req.headers();
    let supplied = h
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|s| s.strip_prefix("Bearer "))
        .unwrap_or("");
    let host = h.get("host").and_then(|v| v.to_str().ok()).unwrap_or("");
    let local = host.starts_with("127.0.0.1:")
        || host == "127.0.0.1"
        || host.starts_with("localhost:")
        || host == "localhost";
    let equal = supplied.len() == s.token.len()
        && supplied
            .bytes()
            .zip(s.token.bytes())
            .fold(0u8, |n, (a, b)| n | (a ^ b))
            == 0;
    if h.contains_key("origin") || !local || !equal {
        return ApiError::new("unauthorized", "接続の認証に失敗しました。", 401).into_response();
    }
    if *s.closing.borrow() {
        return ApiError::new("daemon_closing", "Daemonは終了処理中です。", 503).into_response();
    }
    let trace = neura_native_core::performance::context();
    let mut response = if let Some(id) = trace {
        // Accept only UUID correlation, never copy arbitrary header text to evidence.
        let id = req.headers().get("x-neura-perf-id").and_then(|v|v.to_str().ok())
            .filter(|v| uuid::Uuid::parse_str(v).is_ok()).unwrap_or(&id).to_owned();
        neura_native_core::performance::event(&id, "http.received");
        let response = neura_native_core::performance::REQUEST.scope(id.clone(), next.run(req)).await;
        neura_native_core::performance::event(&id, "http.response");
        response
    } else { next.run(req).await };
    response
        .headers_mut()
        .insert("cache-control", "no-store".parse().unwrap());
    response
}
async fn state_get(State(s): State<Arc<AppState>>) -> Result<Json<Value>, ApiError> {
    Ok(Json(s.snapshot().await?))
}
async fn capabilities() -> Json<Value> {
    let mut p = Vec::new();
    for provider in ["codex", "claude"] {
        p.push(json!({"provider":provider,"available":crate::providers::integration::executable(provider).await.is_ok()}));
    }
    Json(json!({"protocolVersion":1,"features":FEATURES,"providers":p,"remoteAccess":false}))
}
async fn usage(State(s): State<Arc<AppState>>) -> Json<Value> {
    Json(json!({"providers":s.usage.read().await}))
}
fn after(q: &HashMap<String, String>) -> Result<u64, ApiError> {
    let Some(raw) = q.get("after") else {
        return Ok(0);
    };
    let raw = raw.trim();
    let value = if raw.is_empty() {
        0.0
    } else {
        raw.parse::<f64>().map_err(|_| invalid())?
    };
    if !value.is_finite() || value < 0.0 || value.fract() != 0.0 || value > 9_007_199_254_740_991.0
    {
        return Err(invalid());
    }
    Ok(value as u64)
}
async fn notifications(
    State(s): State<Arc<AppState>>,
    Query(q): Query<HashMap<String, String>>,
) -> Result<Json<Value>, ApiError> {
    Ok(Json(
        s.store
            .call("notifications", json!({"after":after(&q)?}))
            .await?,
    ))
}
async fn events(
    State(s): State<Arc<AppState>>,
    Query(q): Query<HashMap<String, String>>,
) -> Result<Json<Value>, ApiError> {
    Ok(Json(
        json!({"events":s.store.call("events",json!({"after":after(&q)?})).await?}),
    ))
}
async fn agents(
    State(s): State<Arc<AppState>>,
    Query(q): Query<HashMap<String, String>>,
) -> Result<Json<Value>, ApiError> {
    if let Some(options) = q.get("options") {
        let options: Value = serde_json::from_str(options).map_err(|_| invalid())?;
        return Ok(Json(
            s.providers.agents.query(options).await.map_err(provider_error)?,
        ));
    }
    Ok(Json(s.providers.snapshot().await.map_err(provider_error)?))
}
async fn agent(
    State(s): State<Arc<AppState>>,
    Path(key): Path<String>,
    Query(q): Query<HashMap<String, String>>,
) -> Result<Json<Value>, ApiError> {
    id(&key)?;
    if q.get("cursor")
        .is_some_and(|v| v.encode_utf16().count() > 4096)
    {
        return Err(invalid());
    }
    Ok(Json(
        s.providers
            .agents
            .read(&key, q.get("cursor").map(String::as_str))
            .await
            .map_err(provider_error)?,
    ))
}
async fn channel(
    State(s): State<Arc<AppState>>,
    Path((key, action)): Path<(String, String)>,
    headers: HeaderMap,
    Json(body): Json<Value>,
) -> Result<Json<Value>, ApiError> {
    id(&key)?;
    if !s.providers.verify_channel(
        &key,
        headers
            .get("x-neura-channel-token")
            .and_then(|v| v.to_str().ok())
            .unwrap_or(""),
    ) {
        return Err(ApiError::new(
            "channel_forbidden",
            "Channels認証が必要です。",
            403,
        ));
    }
    Ok(Json(
        match action.as_str() {
            "channel" => s.providers.channel(&key).await,
            "channel-ack" => {
                id(text(&body, "nonce")?)?;
                s.providers
                    .agents
                    .acknowledge_channel(&key, text(&body, "nonce")?)
                    .await
            }
            _ => return Err(invalid()),
        }
        .map_err(provider_error)?,
    ))
}
async fn output(
    State(s): State<Arc<AppState>>,
    Path(key): Path<String>,
    Query(q): Query<HashMap<String, String>>,
) -> Result<Json<Value>, ApiError> {
    s.pty.check_healthy()?;
    id(&key)?;
    let t = s
        .store
        .get("terminals", &key)
        .await?
        .ok_or_else(|| ApiError::new("terminal_missing", "ターミナルがありません。", 404))?;
    let mut page=s.store.call("output",json!({"terminalId":key,"after":after(&q)?,"chunksOnly":q.get("chunksOnly").is_some_and(|v|v=="true")})).await?;
    for k in ["status", "cols", "rows"] {
        page[k] = t[k].clone();
    }
    Ok(Json(page))
}
async fn workspace_read(
    State(s): State<Arc<AppState>>,
    Path((key, action)): Path<(String, String)>,
    Query(q): Query<HashMap<String, String>>,
) -> Result<Json<Value>, ApiError> {
    let w = s.entity("workspaces", &key).await?;
    let root = text(&w, "path")?;
    let path = q.get("path").map(String::as_str).unwrap_or("");
    if path.encode_utf16().count() > 4096
        || (["file", "diff"].contains(&action.as_str()) && path.is_empty())
    {
        return Err(invalid());
    }
    if action == "github" && (w["kind"] == "folder" || w["kind"] == "scratch") {
        return Err(ApiError::new(
            "git_required",
            "Gitリポジトリが必要です。",
            400,
        ));
    }
    let value = match action.as_str() {
        "checks" => {
            if w["kind"] == "folder" || w["kind"] == "scratch" {
                json!({"state":"unsupported","checks":[],"fetchedAt":chrono::Utc::now().to_rfc3339()})
            } else {
                s.github.checks(root).await?
            }
        }
        "github" => {
            s.github
                .status(
                    root,
                    q.get("refresh").is_some_and(|v| v == "true"),
                    w.get("pullRequestSource"),
                )
                .await?
        }
        "files" | "file" => {
            if w["kind"] == "scratch" {
                return Err(ApiError::new(
                    "folder_required",
                    "フォルダを紐づけてください。",
                    400,
                ));
            }
            if action == "files" {
                work::files(root, path).await?
            } else {
                work::file(root, path).await?
            }
        }
        "git" | "diff" => {
            if w["kind"] == "folder" || w["kind"] == "scratch" {
                return Err(ApiError::new(
                    "git_required",
                    "Gitを使用していません。",
                    400,
                ));
            }
            if action == "git" {
                work::git_status(root).await?
            } else {
                work::diff(root, path).await?
            }
        }
        _ => return Err(invalid()),
    };
    Ok(Json(value))
}
async fn project_read(
    State(s): State<Arc<AppState>>,
    Path((key, action)): Path<(String, String)>,
    Query(q): Query<HashMap<String, String>>,
) -> Result<Json<Value>, ApiError> {
    let p = s.entity("projects", &key).await?;
    let root = text(&p, "path")?;
    let query = q.get("query").map(|v| v.trim()).unwrap_or("");
    if query.encode_utf16().count() > 500 {
        return Err(invalid());
    }
    if action == "pull-requests" && p["isGit"] == false {
        return Err(ApiError::new(
            "git_required",
            "Gitリポジトリが必要です。",
            400,
        ));
    }
    Ok(Json(match action.as_str() {
        "setup-scripts" => work::detect_setup(root).await,
        "pull-requests" => s.github.pull_requests(root, query).await?,
        _ => return Err(invalid()),
    }))
}
async fn browser_poll(
    State(s): State<Arc<AppState>>,
    Json(body): Json<Value>,
) -> Result<Json<Value>, ApiError> {
    let _gate = s.browser_poll_gate.lock().await;
    let snapshot = s.snapshot().await?;
    Ok(Json(s.browser.poll(body, &snapshot)?))
}
async fn browser_call(
    State(s): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(body): Json<Value>,
) -> Result<Json<Value>, ApiError> {
    let verified = s.providers.verify_browser(
        body["terminalId"].as_str().unwrap_or(""),
        headers
            .get("x-neura-browser-token")
            .and_then(|v| v.to_str().ok())
            .unwrap_or(""),
    );
    let snapshot = s.snapshot().await?;
    Ok(Json(s.browser.call(body, &snapshot, verified).await?))
}
async fn stream(
    State(s): State<Arc<AppState>>,
    Query(query): Query<HashMap<String, String>>,
    ws: WebSocketUpgrade,
) -> Result<Response, ApiError> {
    let native_id = query.get("nativeId").cloned();
    if let Some(key) = &native_id {
        id(key)?;
    }
    Ok(ws
        .max_message_size(1024)
        .max_frame_size(1024)
        .on_upgrade(move |socket| stream_session(socket, s, native_id)))
}
async fn stream_session(socket: WebSocket, s: Arc<AppState>, native_id: Option<String>) {
    let _browser_lease = match native_id {
        Some(key) => match s.browser.attach_stream(&key) {
            Ok(lease) => Some(lease),
            Err(_) => return,
        },
        None => None,
    };
    let mut closing = s.closing.subscribe();
    if *closing.borrow() {
        return;
    }
    let mut changes = s.events.subscribe();
    let (mut sink, mut source) = socket.split();
    if tokio::time::timeout(
        Duration::from_secs(2),
        sink.send(Message::Text(
            json!({"type":"ready","epoch":s.epoch}).to_string().into(),
        )),
    )
    .await
    .map_or(true, |r| r.is_err())
    {
        return;
    }
    let mut ping = tokio::time::interval(Duration::from_secs(15));
    ping.tick().await;
    let mut pong = true;
    loop {
        tokio::select! {_=closing.changed()=>break,change=changes.recv()=>{let Ok(mut c)=change else{break;};tokio::time::sleep(Duration::from_millis(16)).await;let mut ids:HashSet<String>=c.terminals.drain(..).collect();let mut agent_ids:HashSet<String>=c.agent_terminals.drain(..).collect();loop{match changes.try_recv(){Ok(v)=>{c.state|=v.state;c.browser|=v.browser;ids.extend(v.terminals);agent_ids.extend(v.agent_terminals);},Err(broadcast::error::TryRecvError::Empty)=>break,Err(_)=>return,}}let value=json!({"type":"changed","state":c.state,"terminals":ids,"agentTerminals":agent_ids,"browser":c.browser});if tokio::time::timeout(Duration::from_secs(2),sink.send(Message::Text(value.to_string().into()))).await.map_or(true,|r|r.is_err()){break;}},message=source.next()=>match message{Some(Ok(Message::Pong(_)))=>pong=true,Some(Ok(Message::Ping(v)))=>{if tokio::time::timeout(Duration::from_secs(2),sink.send(Message::Pong(v))).await.map_or(true,|r|r.is_err()){break;}},Some(Ok(Message::Close(_)))|None|Some(Err(_))=>break,_=>{}},_=ping.tick()=>{if !pong{break;}pong=false;if tokio::time::timeout(Duration::from_secs(2),sink.send(Message::Ping(vec![].into()))).await.map_or(true,|r|r.is_err()){break;}}}
    }
    let _ = tokio::time::timeout(Duration::from_secs(2), sink.close()).await;
}
async fn command(
    State(s): State<Arc<AppState>>,
    Json(body): Json<Value>,
) -> Result<Json<Value>, ApiError> {
    if body["command"]["type"] == "agent.instruction" {
        // Keep the durable row, in-memory registry and operation journal in
        // sync even if the MCP/HTTP caller disconnects during the write.
        // Tokio task-locals are not inherited by spawn. Scope the detached
        // worker itself so correlation also survives cancellation of its caller.
        let request = neura_native_core::performance::REQUEST.try_with(Clone::clone).ok();
        return tokio::spawn(async move {
            if let Some(request) = request {
                neura_native_core::performance::REQUEST
                    .scope(request, command_inner(State(s), Json(body)))
                    .await
            } else {
                command_inner(State(s), Json(body)).await
            }
        })
        .await
        .map_err(|_| ApiError::storage())?;
    }
    command_inner(State(s), Json(body)).await
}
async fn command_inner(
    State(s): State<Arc<AppState>>,
    Json(body): Json<Value>,
) -> Result<Json<Value>, ApiError> {
    let (op, c) = contracts::envelope(body)?;
    let started = std::time::Instant::now();
    let traced = !["terminal.input", "terminal.resize"].contains(&c["type"].as_str().unwrap_or(""));
    if traced {
        s.diagnostics
            .record(Phase::Received, c["type"].as_str(), Some(&op), None);
    }
    let digest = work::hash(&c.to_string());
    let lock = {
        let mut locks = s.operations.lock().await;
        locks.retain(|_, v| v.strong_count() > 0);
        if let Some(lock) = locks.get(&op).and_then(Weak::upgrade) {
            lock
        } else {
            let lock = Arc::new(Mutex::new(()));
            locks.insert(op.clone(), Arc::downgrade(&lock));
            lock
        }
    };
    let _guard = lock.lock().await;
    let prior = s.store.call("operation", json!({"id":op})).await?;
    if !prior.is_null() {
        if prior["hash"] != digest {
            return Err(ApiError::new(
                "operation_conflict",
                "同じ操作IDに別の内容が指定されています。",
                409,
            ));
        }
        if prior["status"] == "pending" {
            return Err(ApiError::new(
                "operation_unknown",
                "前回の操作結果を確認できません。",
                409,
            ));
        }
        let result: Value = serde_json::from_str(prior["result"].as_str().unwrap_or("null"))
            .map_err(|_| ApiError::storage())?;
        if prior["status"] == "failed" {
            return Err(ApiError::new(
                result["code"].as_str().unwrap_or("operation_failed"),
                result["message"].as_str().unwrap_or("操作に失敗しました。"),
                result["status"].as_u64().unwrap_or(500) as u16,
            ));
        }
        return Ok(Json(result));
    }
    s.store
        .call("operation_start", json!({"id":op,"hash":digest}))
        .await?;
    if traced {
        s.diagnostics.record(
            Phase::Executing,
            c["type"].as_str(),
            Some(&op),
            Some(started.elapsed().as_secs_f64() * 1000.0),
        );
    }
    let result = execute(s.clone(), &c, &op).await;
    if traced || result.is_err() {
        s.diagnostics.record(
            if result.is_ok() {
                Phase::Success
            } else {
                Phase::Failure
            },
            c["type"].as_str(),
            Some(&op),
            Some(started.elapsed().as_secs_f64() * 1000.0),
        );
    }
    let (status, value) = match &result {
        Ok(value) => ("done", value.clone()),
        Err(e) => (
            "failed",
            json!({"code":e.error,"message":e.message,"status":e.status}),
        ),
    };
    s.store
        .call(
            "operation_finish",
            json!({"id":op,"status":status,"result":value.to_string()}),
        )
        .await?;
    result.map(Json)
}
fn now() -> String {
    chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
}
fn basename(path: &str) -> String {
    std::path::Path::new(path)
        .file_name()
        .unwrap_or_default()
        .to_string_lossy()
        .into_owned()
}
async fn execute(s: Arc<AppState>, c: &Value, op: &str) -> Result<Value, ApiError> {
    let kind = text(c, "type")?;
    if kind.starts_with("agent.") {
        return s.providers.agents.command(c).await.map_err(provider_error);
    }
    let project = if let Some(key) = c["projectId"].as_str() {
        Some(key.to_owned())
    } else if let Some(key) = c["workspaceId"].as_str() {
        Some(text(&s.entity("workspaces", key).await?, "projectId")?.to_owned())
    } else {
        None
    };
    let workspace = c["workspaceId"]
        .as_str()
        .map(String::from)
        .or_else(|| c["terminalId"].as_str().map(|v| format!("terminal:{v}")));
    let catalogue = [
        "project.add",
        "project.create",
        "project.attach",
        "project.remove",
    ]
    .contains(&kind);
    let exclusive = ["project.remove", "project.attach"].contains(&kind);
    let _scope = s
        .mutation
        .enter(
            project.as_deref(),
            workspace.as_deref(),
            exclusive,
            catalogue,
        )
        .await;

    match kind {
        "project.create" => {
            let directory = s.data_dir.join("projects").join(op);
            tokio::fs::create_dir_all(&directory)
                .await
                .map_err(|_| ApiError::storage())?;
            let path = tokio::fs::canonicalize(directory)
                .await
                .map_err(|_| ApiError::storage())?
                .to_string_lossy()
                .into_owned();
            let p = json!({"id":op,"name":c["name"],"path":path,"folderless":true,"isGit":false,"createdAt":now()});
            let w = json!({"id":Uuid::new_v4().to_string(),"projectId":op,"name":"フリー","path":path,"branch":"","kind":"scratch","createdAt":p["createdAt"]});
            s.store
                .call("put_pair", json!({"project":p,"workspace":w}))
                .await?;
            Ok(p)
        }
        "project.add" | "project.attach" => {
            let (path, is_git) = work::project_folder(text(c, "path")?).await?;
            let projects = s.store.list("projects").await?;
            let workspaces = s.store.list("workspaces").await?;
            if workspaces
                .iter()
                .any(|w| w["path"] == path && w["kind"] == "scratch")
            {
                return Err(ApiError::new(
                    "managed_folder",
                    "管理対象のフリーフォルダです。",
                    409,
                ));
            }
            let existing = projects.iter().find(|p| p["path"] == path);
            let mut p = if kind == "project.attach" {
                let p = s.entity("projects", text(c, "projectId")?).await?;
                if p["folderless"] != true {
                    return Err(ApiError::new(
                        "folder_already_attached",
                        "フォルダは設定済みです。",
                        409,
                    ));
                }
                if existing.is_some() {
                    return Err(ApiError::new(
                        "project_exists",
                        "フォルダは登録済みです。",
                        409,
                    ));
                }
                if workspaces.iter().any(|w| w["path"] == path) {
                    return Err(ApiError::new(
                        "workspace_exists",
                        "作業領域は登録済みです。",
                        409,
                    ));
                }
                p
            } else {
                existing
                    .cloned()
                    .unwrap_or_else(|| json!({"id":op,"name":basename(&path),"createdAt":now()}))
            };
            p["path"] = json!(path);
            p["isGit"] = json!(is_git);
            if kind == "project.attach" {
                p["folderless"] = json!(false);
            }
            let branch = if is_git {
                let b = work::git(&path, &["branch", "--show-current"]).await?;
                if b.trim().is_empty() {
                    "(detached)".into()
                } else {
                    b.trim().to_owned()
                }
            } else {
                String::new()
            };
            let root = if kind == "project.add" {
                workspaces.iter().find(|w| {
                    w["projectId"] == p["id"] && (w["kind"] == "root" || w["kind"] == "folder")
                })
            } else {
                None
            };
            let w = json!({"id":root.map(|w|w["id"].clone()).unwrap_or_else(||json!(if kind=="project.attach"{op.to_owned()}else{Uuid::new_v4().to_string()})),"projectId":p["id"],"name":root.map(|w|w["name"].clone()).unwrap_or_else(||json!(if kind=="project.attach"{basename(&path)}else{"メイン".into()})),"path":path,"branch":branch,"kind":if is_git{"root"}else{"folder"},"createdAt":root.map(|w|w["createdAt"].clone()).unwrap_or(p["createdAt"].clone())});
            if existing.is_some() && kind == "project.add" {
                p = s
                    .store
                    .update("projects", text(&p, "id")?, |v| {
                        v["isGit"] = json!(is_git);
                    })
                    .await?
                    .ok_or_else(ApiError::storage)?;
                if root.is_some() {
                    s.store
                        .update("workspaces", text(&w, "id")?, |v| {
                            for k in ["path", "branch", "kind"] {
                                v[k] = w[k].clone();
                            }
                        })
                        .await?;
                } else {
                    s.store.put("workspaces", w, None).await?;
                }
            } else {
                s.store
                    .call("put_pair", json!({"project":p,"workspace":w}))
                    .await?;
            }
            Ok(p)
        }
        "project.set-worktree-startup"
        | "project.set-default-providers"
        | "project.set-worktree-setup" => {
            let mut p = s.entity("projects", text(c, "projectId")?).await?;
            match kind {
                "project.set-worktree-startup" => p["worktreeStartup"] = c["providers"].clone(),
                "project.set-default-providers" => {
                    for key in ["defaultConversationProvider", "defaultDelegationProvider"] {
                        if let Some(value) = c.get(key) {
                            p[key] = value.clone();
                        }
                    }
                }
                _ => {
                    if p["isGit"] == false {
                        return Err(ApiError::new(
                            "git_required",
                            "Gitリポジトリが必要です。",
                            400,
                        ));
                    }
                    if let Some(script) = c["script"].as_str().filter(|v| !v.is_empty()) {
                        work::setup_path(text(&p, "path")?, script).await?;
                        p["worktreeSetup"] = json!(script);
                    } else {
                        p.as_object_mut().unwrap().remove("worktreeSetup");
                    }
                }
            };
            let keys: Vec<&str> = match kind {
                "project.set-worktree-startup" => vec!["worktreeStartup"],
                "project.set-worktree-setup" => vec!["worktreeSetup"],
                _ => ["defaultConversationProvider", "defaultDelegationProvider"]
                    .into_iter()
                    .filter(|k| c.get(*k).is_some())
                    .collect(),
            };
            s.store
                .update("projects", text(&p, "id")?, |value| {
                    for key in &keys {
                        if let Some(v) = p.get(*key) {
                            value[*key] = v.clone();
                        } else {
                            value.as_object_mut().unwrap().remove(*key);
                        }
                    }
                })
                .await?
                .ok_or_else(ApiError::storage)
        }
        "project.remove" => {
            let key = text(c, "projectId")?;
            s.entity("projects", key).await?;
            let workspaces: Vec<_> = s
                .store
                .list("workspaces")
                .await?
                .into_iter()
                .filter(|w| w["projectId"] == key)
                .collect();
            for w in &workspaces {
                let id = text(w, "id")?;
                if s.setups.lock().await.contains_key(id) {
                    return Err(ApiError::new(
                        "setup_running",
                        "セットアップを実行中です。",
                        409,
                    ));
                }
            }
            for w in &workspaces {
                s.stop_workspace(text(w, "id")?).await?;
            }
            s.store.call("remove_project", json!({"id":key})).await?;
            for w in &workspaces {
                s.providers.agents.forget_workspace(text(w, "id")?).await;
            }
            Ok(json!({"ok":true}))
        }
        "workspace.create" => {
            let p = s.entity("projects", text(c, "projectId")?).await?;
            if p["isGit"] == false {
                return Err(ApiError::new(
                    "git_required",
                    "Gitリポジトリが必要です。",
                    400,
                ));
            }
            if !c["baseRef"].is_null() && !c["pullRequest"].is_null() {
                return Err(ApiError::new(
                    "invalid_source",
                    "作成元は一つだけ指定してください。",
                    400,
                ));
            }
            let root = text(&p, "path")?;
            let target = if let Some(reference) = c["baseRef"].as_str() {
                let commit = work::git(
                    root,
                    &[
                        "rev-parse",
                        "--verify",
                        "--end-of-options",
                        &format!("{reference}^{{commit}}"),
                    ],
                )
                .await?;
                json!({"commit":commit.trim()})
            } else if let Some(pr) = c["pullRequest"].as_str() {
                s.github.fetch_pull_request(root, pr).await?
            } else {
                work::fetch_default(root).await?
            };
            let name = c["name"]
                .as_str()
                .map(String::from)
                .unwrap_or_else(|| format!("worktree-{}", &op[..8]));
            let slug: String = c["name"]
                .as_str()
                .unwrap_or("worktree")
                .chars()
                .map(|v| if v.is_alphanumeric() { v } else { '-' })
                .collect::<String>()
                .split('-')
                .filter(|v| !v.is_empty())
                .collect::<Vec<_>>()
                .join("-")
                .chars()
                .take(40)
                .collect();
            let slug = if slug.is_empty() {
                "work".to_owned()
            } else {
                slug
            };
            let branch = format!("neura/{slug}-{}", &op[..8]);
            let parent = s.data_dir.join("worktrees").join(text(&p, "id")?);
            tokio::fs::create_dir_all(&parent)
                .await
                .map_err(|_| ApiError::storage())?;
            let path = parent
                .join(format!("{slug}-{}", &op[..8]))
                .to_string_lossy()
                .into_owned();
            work::git(
                root,
                &[
                    "worktree",
                    "add",
                    "-b",
                    &branch,
                    &path,
                    text(&target, "commit")?,
                ],
            )
            .await?;
            let mut w = json!({"id":op,"projectId":p["id"],"name":name,"nameSource":if c.get("name").is_some(){"manual"}else{"session"},"path":path,"branch":branch,"kind":"worktree","createdAt":now()});
            if let Some(source) = target.get("pullRequestSource") {
                w["pullRequestSource"] = source.clone();
                w["pullRequestSource"]["localBranch"] = json!(branch);
            }
            s.store.put("workspaces", w.clone(), None).await?;
            let startup = if c["skipStartup"] == true {
                vec![]
            } else {
                p["worktreeStartup"].as_array().cloned().unwrap_or_default()
            };
            let mut errors = Vec::new();
            if p["worktreeSetup"].as_str().is_some_and(|v| !v.is_empty()) {
                start_setup(s.clone(), w.clone(), p.clone(), startup).await?;
                w["setup"] = json!({"status":"running","script":p["worktreeSetup"],"output":""});
            } else {
                for provider in startup {
                    if *s.closing.borrow() {
                        return Err(ApiError::new("setup_cancelled", "終了処理中です。", 500));
                    }
                    if let Some(provider) = provider.as_str() {
                        if s.open(w.clone(), provider, false, &json!({}))
                            .await
                            .is_err()
                        {
                            errors.push(format!("{provider}の自動起動に失敗しました。"));
                        }
                    }
                }
            }
            w["startupErrors"] = json!(errors);
            Ok(w)
        }
        "workspace.setup" => {
            let key = text(c, "workspaceId")?;
            let w = s.entity("workspaces", key).await?;
            if w["kind"] != "worktree" {
                return Err(ApiError::new(
                    "worktree_required",
                    "worktreeを選択してください。",
                    400,
                ));
            }
            if s.setups.lock().await.contains_key(key) {
                return Err(ApiError::new(
                    "setup_running",
                    "セットアップを実行中です。",
                    409,
                ));
            }
            if s.store
                .list("terminals")
                .await?
                .iter()
                .any(|t| t["workspaceId"] == key && t["status"] == "running")
            {
                return Err(ApiError::new(
                    "workspace_running",
                    "実行中のターミナルがあります。",
                    409,
                ));
            }
            let p = s.entity("projects", text(&w, "projectId")?).await?;
            if p["worktreeSetup"].as_str().is_none_or(|v| v.is_empty()) {
                return Err(ApiError::new(
                    "setup_missing",
                    "setup scriptを設定してください。",
                    400,
                ));
            }
            start_setup(s.clone(), w, p, vec![]).await?;
            Ok(json!({"ok":true}))
        }
        "workspace.delete" => {
            let key = text(c, "workspaceId")?;
            let w = s.entity("workspaces", key).await?;
            if w["kind"] != "worktree" {
                return Err(ApiError::new(
                    "worktree_required",
                    "追加worktreeを選択してください。",
                    400,
                ));
            }
            if s.setups.lock().await.contains_key(key) {
                return Err(ApiError::new(
                    "setup_running",
                    "セットアップを実行中です。",
                    409,
                ));
            }
            if c["stopTerminals"] != true
                && s.store
                    .list("terminals")
                    .await?
                    .iter()
                    .any(|t| t["workspaceId"] == key && t["status"] == "running")
            {
                return Err(ApiError::new(
                    "workspace_running",
                    "実行中のターミナルがあります。",
                    409,
                ));
            }
            let p = s.entity("projects", text(&w, "projectId")?).await?;
            verify_delete(&s, &w, c).await?;
            if c["stopTerminals"] == true {
                s.stop_workspace(key).await?;
                verify_delete(&s, &w, c).await?;
            }
            let mut args = vec!["worktree", "remove"];
            if c["discardChanges"] == true {
                args.push("--force");
            }
            args.extend(["--", text(&w, "path")?]);
            work::git(text(&p, "path")?, &args).await?;
            s.store.call("delete_workspace", json!({"id":key})).await?;
            s.providers.agents.forget_workspace(key).await;
            Ok(json!({"ok":true}))
        }
        "workspace.sync-default" => {
            let w = s.entity("workspaces", text(c, "workspaceId")?).await?;
            if w["kind"] != "root" {
                return Err(ApiError::new(
                    "root_required",
                    "メイン作業領域を選択してください。",
                    400,
                ));
            }
            if s.store
                .list("terminals")
                .await?
                .iter()
                .any(|t| t["workspaceId"] == w["id"] && t["status"] == "running")
            {
                return Err(ApiError::new(
                    "workspace_running",
                    "実行中のターミナルがあります。",
                    409,
                ));
            }
            let root = text(&w, "path")?;
            let target = work::fetch_default(root).await?;
            work::sync_default(root, &target).await?;
            s.store
                .update("workspaces", text(&w, "id")?, |value| {
                    value["branch"] = target["branch"].clone()
                })
                .await?
                .ok_or_else(ApiError::storage)
        }
        "terminal.open" => {
            let key = text(c, "workspaceId")?;
            if s.setups.lock().await.contains_key(key) {
                return Err(ApiError::new(
                    "setup_running",
                    "セットアップを実行中です。",
                    409,
                ));
            }
            let w = s.entity("workspaces", key).await?;
            let provider = if let Some(p) = c["provider"].as_str() {
                p.to_owned()
            } else if let Some(resume) = c["resumeId"].as_str() {
                let a = s
                    .providers
                    .agents
                    .get(resume)
                    .await
                    .map_err(provider_error)?;
                serde_json::to_value(a).map_err(|_| invalid())?["provider"]
                    .as_str()
                    .unwrap_or("codex")
                    .to_owned()
            } else {
                let p = s.entity("projects", text(&w, "projectId")?).await?;
                p["defaultConversationProvider"]
                    .as_str()
                    .map(String::from)
                    .unwrap_or_else(|| {
                        let names: HashSet<_> = p["worktreeStartup"]
                            .as_array()
                            .into_iter()
                            .flatten()
                            .filter_map(Value::as_str)
                            .filter(|v| ["claude", "codex"].contains(v))
                            .collect();
                        if names.len() == 1 {
                            names.into_iter().next().unwrap().to_owned()
                        } else {
                            "codex".into()
                        }
                    })
            };
            s.open(w, &provider, c["resume"] == true, c).await
        }
        "terminal.input" => {
            let key = text(c, "terminalId")?;
            s.claim(key, text(c, "clientId")?).await?;
            let data = text(c, "data")?;
            s.pty.input(key, data).await?;
            if data == "\x03" || data == "\x1b" {
                s.providers
                    .agents
                    .claude_interrupted(key, false)
                    .await
                    .map_err(provider_error)?;
            }
            Ok(json!({"ok":true}))
        }
        "terminal.resize" => {
            let key = text(c, "terminalId")?;
            s.claim(key, text(c, "clientId")?).await?;
            s.pty
                .resize(
                    key,
                    c["cols"].as_u64().ok_or_else(invalid)? as u16,
                    c["rows"].as_u64().ok_or_else(invalid)? as u16,
                )
                .await?;
            s.store
                .update("terminals", key, |t| {
                    t["cols"] = c["cols"].clone();
                    t["rows"] = c["rows"].clone();
                })
                .await?;
            Ok(json!({"ok":true}))
        }
        "terminal.stop" => {
            let key = text(c, "terminalId")?;
            s.pty.stop(key).await?;
            s.providers.close(key).await.map_err(provider_error)?;
            Ok(json!({"ok":true}))
        }
        "file.save" => {
            let w = s.entity("workspaces", text(c, "workspaceId")?).await?;
            if w["kind"] == "scratch" {
                return Err(ApiError::new(
                    "folder_required",
                    "フォルダが必要です。",
                    400,
                ));
            }
            work::save_file(
                text(&w, "path")?,
                text(c, "path")?,
                text(c, "content")?,
                text(c, "expectedHash")?,
            )
            .await
        }
        "github.push" | "github.create" | "github.merge" => {
            let w = s.entity("workspaces", text(c, "workspaceId")?).await?;
            if w["kind"] == "folder" || w["kind"] == "scratch" {
                return Err(ApiError::new(
                    "git_required",
                    "Gitリポジトリが必要です。",
                    400,
                ));
            }
            s.github
                .mutate(text(&w, "path")?, c, w.get("pullRequestSource"))
                .await
        }
        _ => Err(ApiError::new(
            "invalid_command",
            "未対応のコマンドです。",
            400,
        )),
    }
}

async fn verify_delete(s: &AppState, w: &Value, c: &Value) -> Result<(), ApiError> {
    let root = text(w, "path")?;
    let key = text(w, "id")?;
    if let Some(cleanup) = c.get("cleanup") {
        let caller = text(cleanup, "callerWorkspaceId")?;
        s.entity("workspaces", caller).await?;
        if caller == key {
            return Err(ApiError::new(
                "workspace_self_cleanup",
                "現在の作業領域は削除できません。",
                409,
            ));
        }
        if c["discardChanges"] == true || c["stopTerminals"] != true {
            return Err(ApiError::new(
                "workspace_cleanup_options",
                "cleanup条件が不正です。",
                409,
            ));
        }
        let agents =
            serde_json::to_value(s.providers.agents.list().await).map_err(|_| invalid())?;
        let active: Vec<_> = agents
            .as_array()
            .ok_or_else(invalid)?
            .iter()
            .filter(|a| a["workspaceId"] == key)
            .collect();
        let unfinished = active.iter().any(|a| {
            !a["turnId"].is_null()
                || ["working", "waiting", "failed"].contains(&a["status"].as_str().unwrap_or(""))
                || ["pending", "reports", "watching"]
                    .iter()
                    .any(|k| a[*k].as_array().is_some_and(|v| !v.is_empty()))
        });
        let unverified = s.store.list("terminals").await?.iter().any(|t| {
            t["workspaceId"] == key
                && t["status"] == "running"
                && if t["provider"] == "codex" {
                    !active.iter().any(|a| a["terminalId"] == t["id"])
                } else {
                    t["activity"] != "idle"
                }
        });
        if unfinished || unverified {
            return Err(ApiError::new(
                "workspace_task_unfinished",
                "未完了の作業を保持します。",
                409,
            ));
        }
        let head = work::git(root, &["rev-parse", "HEAD"]).await?;
        if head.trim() != text(cleanup, "expectedHead")? {
            return Err(ApiError::new(
                "workspace_head_changed",
                "HEADが変更されています。",
                409,
            ));
        }
        s.github
            .verify_cleanup(
                root,
                cleanup["mergedPR"].as_u64().ok_or_else(invalid)?,
                head.trim(),
            )
            .await?;
    }
    if c["discardChanges"] == true {
        return Ok(());
    }
    if !work::git(
        root,
        &[
            "ls-files",
            "--others",
            "--ignored",
            "--exclude-standard",
            "--directory",
            "-z",
        ],
    )
    .await?
    .is_empty()
    {
        return Err(ApiError::new(
            "workspace_ignored_files",
            "無視対象ファイルがあります。",
            409,
        ));
    }
    if !work::git(
        root,
        &["status", "--porcelain=v1", "-z", "--untracked-files=normal"],
    )
    .await?
    .is_empty()
    {
        return Err(ApiError::new(
            "workspace_dirty",
            "未保存の変更があります。",
            409,
        ));
    }
    if let Some(cleanup) = c.get("cleanup") {
        if work::git(root, &["rev-parse", "HEAD"]).await?.trim() != text(cleanup, "expectedHead")? {
            return Err(ApiError::new(
                "workspace_head_changed",
                "HEADが変更されています。",
                409,
            ));
        }
    }
    Ok(())
}
async fn setup_update(s: &AppState, key: &str, setup: Value) -> Result<(), ApiError> {
    loop {
        let Some(expected) = s.store.get("workspaces", key).await? else {
            return Ok(());
        };
        let mut updated = expected.clone();
        updated["setup"] = setup.clone();
        if s.store
            .call(
                "compare_put",
                json!({"table":"workspaces","id":key,"expected":expected,"value":updated}),
            )
            .await?
            == true
        {
            return Ok(());
        }
    }
}
async fn start_setup(
    s: Arc<AppState>,
    w: Value,
    p: Value,
    startup: Vec<Value>,
) -> Result<(), ApiError> {
    let key = text(&w, "id")?.to_owned();
    let root = text(&w, "path")?.to_owned();
    let script = text(&p, "worktreeSetup")?.to_owned();
    let path = work::setup_path(&root, &script).await?;
    setup_update(
        &s,
        &key,
        json!({"status":"running","script":script,"output":""}),
    )
    .await?;
    let (begin, wait) = tokio::sync::oneshot::channel();
    let (cancel, mut cancelled) = tokio::sync::watch::channel(false);
    let task_key = key.clone();
    let owner = s.clone();
    let task = tokio::spawn(async move {
        let _ = wait.await;
        let mut output = String::new();
        let result = async {
            use std::process::Stdio;
            use tokio::io::AsyncReadExt;
            let lease=crate::process_tree::reserve().await.map_err(|_|ApiError::new("process_supervisor_failed","プロセス監督に接続できません。",503))?;
            let mut child = tokio::process::Command::new("/bin/bash")
            .env(crate::process_tree::OWNER_ENV,lease.token())
            .arg(path)
            .current_dir(&root)
            .env("NEURA_PROJECT_ROOT", text(&p, "path")?)
            .env("NEURA_WORKTREE_PATH", &root)
            .stdin(Stdio::null())
            .kill_on_drop(true)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .process_group(0)
            .spawn()
            .map_err(|_| ApiError::new("setup_failed", "setup scriptを起動できません。", 500))?;
            lease.attach(child.id().ok_or_else(ApiError::storage)?).await.map_err(|_|ApiError::new("process_monitor_failed","setupの所有確認ができません。",500))?;
            let (tx, mut rx) = tokio::sync::mpsc::channel::<String>(8);
            async fn read(
                mut stream: impl tokio::io::AsyncRead + Unpin,
                tx: tokio::sync::mpsc::Sender<String>,
            ) {
                let mut bytes = [0u8; 8192];
                let mut carry = Vec::new();
                loop {
                    let n = stream.read(&mut bytes).await.unwrap_or(0);
                    carry.extend_from_slice(&bytes[..n]);
                    let mut text = String::new();
                    loop {
                        match std::str::from_utf8(&carry) {
                            Ok(v) => {
                                text.push_str(v);
                                carry.clear();
                                break;
                            }
                            Err(e) => {
                                let valid = e.valid_up_to();
                                text.push_str(std::str::from_utf8(&carry[..valid]).unwrap());
                                carry.drain(..valid);
                                if let Some(len) = e.error_len() {
                                    text.push('\u{fffd}');
                                    carry.drain(..len);
                                } else {
                                    if n == 0 && !carry.is_empty() {
                                        text.push('\u{fffd}');
                                        carry.clear();
                                    }
                                    break;
                                }
                            }
                        }
                    }
                    if !text.is_empty() && tx.send(text).await.is_err() {
                        break;
                    }
                    if n == 0 {
                        break;
                    }
                }
            }
            let stdout = child.stdout.take().ok_or_else(ApiError::storage)?;
            let stderr = child.stderr.take().ok_or_else(ApiError::storage)?;
            let a = tokio::spawn(read(stdout, tx.clone()));
            let b = tokio::spawn(read(stderr, tx));
            let until = tokio::time::Instant::now() + Duration::from_secs(15 * 60);
            let mut last = tokio::time::Instant::now();
            let status={let completed = async {
                let consume=async {while let Some(bytes) = rx.recv().await {
                    output.push_str(&bytes);
                    if output.len() > 65536 {
                        let mut cut = output.len() - 65536;
                        while !output.is_char_boundary(cut) {
                            cut += 1;
                        }
                        output.drain(..cut);
                    }
                    if last.elapsed() >= Duration::from_millis(32) {
                        setup_update(
                            &s,
                            &task_key,
                            json!({"status":"running","script":script,"output":output}),
                        )
                        .await?;
                        last = tokio::time::Instant::now();
                    }
                }
                Ok::<(),ApiError>(())};
                let reap=async{let status=child.wait().await.map_err(|_|ApiError::storage())?;lease.stop().await.map_err(|_|ApiError::new("process_cleanup_failed","setup子孫の終了を確認できません。",500))?;Ok::<_,ApiError>(status)};
                let(_,status)=tokio::try_join!(consume,reap)?;Ok(status)
            };
            tokio::pin!(completed);
            let status=tokio::select!{value=&mut completed=>Some(value),_=cancelled.changed()=>None,_=tokio::time::sleep_until(until)=>None};
            match status{Some(value)=>value,None=>{let stopped=lease.stop().await;let drained=tokio::time::timeout(Duration::from_secs(10),&mut completed).await;if stopped.is_err(){return Err(ApiError::new("process_cleanup_failed","setup子孫の終了を確認できません。",500));}match drained{Ok(Err(e))=>Err(e),Ok(Ok(_))=>Err(ApiError::new("setup_cancelled","setup scriptを中断しました。",500)),Err(_)=>Err(ApiError::new("setup_stop_timeout","setup終了を確認できません。",500))}}}
            };
            a.abort();b.abort();let status=status?;
            if !status.success() {
                return Err(ApiError::new(
                    "setup_failed",
                    "setup scriptが失敗しました。",
                    500,
                ));
            }
            for provider in startup {
                if *s.closing.borrow(){return Err(ApiError::new("setup_cancelled","終了処理中です。",500));}
                if let Some(provider) = provider.as_str() {
                    if s.open(w.clone(), provider, false, &json!({}))
                        .await
                        .is_err()
                    {
                        output.push_str(&format!("\n{provider}の自動起動に失敗しました。"));
                    }
                }
            }
            Ok(())
        }
        .await;
        let cleanup_error = result
            .as_ref()
            .err()
            .filter(|e| !["setup_cancelled", "setup_failed"].contains(&e.error.as_str()))
            .cloned();
        let setup = match result {
            Ok(()) => json!({"status":"succeeded","script":script,"output":output}),
            Err(e) => json!({"status":"failed","script":script,"output":output,"error":e.message}),
        };
        let persisted = setup_update(&s, &task_key, setup).await;
        s.setups.lock().await.remove(&task_key);
        persisted?;
        if let Some(e) = cleanup_error {
            Err(e)
        } else {
            Ok(())
        }
    });
    owner
        .setups
        .lock()
        .await
        .insert(key, SetupJob { cancel, task });
    let _ = begin.send(());
    Ok(())
}
