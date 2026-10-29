//! Concrete bindings used by the native daemon and PTY launch path.
use super::{
    agents::Agents,
    claude::{self, CompletionMonitor},
    codex::{self, CodexRpc},
    FutureResult, ProviderRuntime, ProviderStore, Result,
};
use crate::{pty::PtyRuntime, store::StoreHandle};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex as StdMutex,
    },
    time::Duration,
};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, BufReader},
    net::UnixListener,
    sync::Mutex,
    task::JoinHandle,
};

impl ProviderStore for StoreHandle {
    fn call<'a>(&'a self, op: &'a str, args: Value) -> FutureResult<'a, Value> {
        Box::pin(async move {
            StoreHandle::call(self, op, args)
                .await
                .map_err(|e| e.to_string())
        })
    }
}
struct NativeRuntime {
    pty: PtyRuntime,
    codex: Mutex<HashMap<String, Arc<CodexRpc>>>,
}
impl ProviderRuntime for NativeRuntime {
    fn rpc<'a>(
        &'a self,
        terminal: &'a str,
        method: &'a str,
        params: Value,
    ) -> FutureResult<'a, Value> {
        Box::pin(async move {
            let live = self.codex.lock().await.get(terminal).cloned();
            if let Some(rpc) = live {
                return rpc.call(method, params).await;
            }
            if method != "thread/turns/list" {
                return Err("agent_offline".into());
            }
            let (events, _) = super::event_queue::channel();
            let rpc =
                CodexRpc::start(&executable("codex").await?, &environment(), &[], events).await?;
            let result = rpc.call(method, params).await;
            let stopped = rpc.close().await;
            stopped?;
            result
        })
    }
    fn reply<'a>(&'a self, terminal: &'a str, id: Value, result: Value) -> FutureResult<'a, ()> {
        Box::pin(async move {
            let rpc = self
                .codex
                .lock()
                .await
                .get(terminal)
                .cloned()
                .ok_or("agent_offline")?;
            rpc.reply(id, result).await
        })
    }
    fn interrupt<'a>(&'a self, terminal: &'a str, waiting: bool) -> FutureResult<'a, ()> {
        Box::pin(async move {
            self.pty
                .input(terminal, if waiting { "\x1b" } else { "\x03" })
                .await
                .map_err(|e| e.to_string())
        })
    }
}
pub struct LaunchSpec {
    pub program: String,
    pub args: Vec<String>,
    pub env: HashMap<String, String>,
    pub agent_id: Option<String>,
}
#[derive(Default)]
struct TerminalLife {
    gate: Mutex<()>,
    closing: AtomicBool,
}
#[derive(Default)]
struct Lifecycle {
    shutting_down: bool,
    terminals: HashMap<String, Arc<TerminalLife>>,
}
struct PrepareGuard {
    service: std::sync::Weak<ProviderService>,
    terminal: String,
    armed: bool,
}
impl Drop for PrepareGuard {
    fn drop(&mut self) {
        if self.armed {
            if let (Some(service), Ok(runtime)) = (
                self.service.upgrade(),
                tokio::runtime::Handle::try_current(),
            ) {
                let terminal = self.terminal.clone();
                runtime.spawn(async move {
                    let _ = service.close(&terminal).await;
                });
            }
        }
    }
}
pub struct ProviderService {
    lifecycle: StdMutex<Lifecycle>,
    cleanup: super::cleanup::CloseTasks,
    pub agents: Arc<Agents>,
    runtime: Arc<NativeRuntime>,
    store: StoreHandle,
    monitor: Arc<CompletionMonitor>,
    endpoint: String,
    token_file: String,
    credentials: StdMutex<HashMap<String, (String, String)>>,
    supported: Mutex<HashMap<String, Result<()>>>,
    hooks: Mutex<HashMap<String, (PathBuf, JoinHandle<()>)>>,
}
impl ProviderService {
    pub async fn new(
        store: StoreHandle,
        pty: PtyRuntime,
        endpoint: String,
        token_file: String,
    ) -> Result<Arc<Self>> {
        let mut exits = pty.subscribe_exit();
        let runtime = Arc::new(NativeRuntime {
            pty,
            codex: Mutex::new(HashMap::new()),
        });
        let agents = Arc::new(Agents::new(Arc::new(store.clone()), runtime.clone()).await?);
        let monitor = CompletionMonitor::start(agents.clone())?;
        let this = Arc::new(Self {
            lifecycle: StdMutex::new(Lifecycle::default()),
            cleanup: super::cleanup::CloseTasks::default(),
            agents,
            runtime,
            store,
            monitor,
            endpoint,
            token_file,
            credentials: StdMutex::new(HashMap::new()),
            supported: Mutex::new(HashMap::new()),
            hooks: Mutex::new(HashMap::new()),
        });
        let weak = Arc::downgrade(&this);
        tokio::spawn(async move {
            loop {
                match exits.recv().await {
                    Ok(exit) => {
                        let Some(service) = weak.upgrade() else { break };
                        tokio::spawn(async move {
                            let _ = service.close(&exit.terminal_id).await;
                        });
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {
                        let Some(service) = weak.upgrade() else { break };
                        let ids: Vec<_> = service
                            .credentials
                            .lock()
                            .unwrap()
                            .keys()
                            .cloned()
                            .collect();
                        for terminal in ids {
                            if service.runtime.pty.pid(&terminal).is_none() {
                                let service = service.clone();
                                tokio::spawn(async move {
                                    let _ = service.close(&terminal).await;
                                });
                            }
                        }
                    }
                    Err(_) => break,
                }
            }
        });
        let weak = Arc::downgrade(&this);
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(Duration::from_secs(60)).await;
                let Some(service) = weak.upgrade() else { break };
                let _ = service.agents.reconcile_channels().await;
                let sessions = service.runtime.codex.lock().await.clone();
                for (terminal, rpc) in sessions {
                    if let Ok(Some(t)) = service.store.get("terminals", &terminal).await {
                        if let Some(workspace) = t["workspaceId"].as_str() {
                            if let Ok(Some(w)) = service.store.get("workspaces", workspace).await {
                                let _ = reconcile_codex(&service.agents, &rpc, &terminal, &w).await;
                            }
                        }
                    }
                }
            }
        });
        Ok(this)
    }
    pub fn verify_channel(&self, terminal: &str, token: &str) -> bool {
        self.credentials
            .lock()
            .unwrap()
            .get(terminal)
            .is_some_and(|v| equal(&v.0, token))
    }
    pub fn verify_browser(&self, terminal: &str, token: &str) -> bool {
        self.credentials
            .lock()
            .unwrap()
            .get(terminal)
            .is_some_and(|v| equal(&v.1, token))
    }
    pub async fn prepare(
        self: &Arc<Self>,
        workspace: &Value,
        terminal: &str,
        provider: &str,
        resume: Option<String>,
        parent: Option<String>,
        prompt: Option<String>,
        choose_history: bool,
    ) -> Result<LaunchSpec> {
        let life = {
            let mut lifecycle = self.lifecycle.lock().unwrap();
            if lifecycle.shutting_down {
                return Err("providers_shutting_down".into());
            }
            lifecycle
                .terminals
                .entry(terminal.to_owned())
                .or_default()
                .clone()
        };
        let mut cancelled = PrepareGuard {
            service: Arc::downgrade(self),
            terminal: terminal.to_owned(),
            armed: true,
        };
        let gate = life.gate.lock().await;
        let result=async {
            if life.closing.load(Ordering::Acquire){return Err("provider_terminal_closing".into());}
        let program = executable(provider).await?;
        let mut env = environment();
        if provider == "shell" {
            return Ok(LaunchSpec {
                program,
                args: vec!["-l".into()],
                env,
                agent_id: None,
            });
        }
        self.check_support(provider, &program).await?;
        let binary = std::env::current_exe().map_err(|e| e.to_string())?;
        let channel_token = credential();
        let browser_token = credential();
        self.credentials.lock().unwrap().insert(
            terminal.into(),
            (channel_token.clone(), browser_token.clone()),
        );
        let result = if provider == "claude" {
            async {
    self.agents.prepare_claude(workspace.clone(),terminal,resume.clone(),parent,prompt).await?;
    let socket=self.hook_socket(terminal).await?;env.insert("NEURA_ACTIVITY_SOCKET".into(),socket.display().to_string());
    let mut config=codex::mcp_config(&binary,&self.endpoint,&self.token_file,workspace["id"].as_str().ok_or("workspace id")?,terminal,&browser_token);config["type"]=json!("stdio");config["env"]["NEURA_CHANNEL_TOKEN"]=json!(channel_token);config["env"]["NEURA_SUPERVISION_CHANNEL"]=json!("claude");
    let instructions=format!("{}\nThis Claude terminal is a registered neuraOS task. Use task_list and currentTerminalId to find its task ID. Channels deliver delegated instructions and untrusted report notifications. Keep the standard Claude Channels startup confirmation; never claim delivery without a confirmed receipt.",include_str!("session-instructions.txt"));
    let mut args=vec!["--permission-mode".into(),"bypassPermissions".into(),"--dangerously-load-development-channels".into(),"server:neuraos".into(),"--mcp-config".into(),json!({"mcpServers":{"neuraos":config}}).to_string(),"--append-system-prompt".into(),instructions];args.extend(claude::activity_arguments(&binary,"claude"));if let Some(id)=resume{args.extend(["--resume".into(),id]);}else if choose_history{args.push("--resume".into());}Ok(LaunchSpec{program:program.clone(),args,env,agent_id:None})
   }.await
        } else if provider == "codex" {
            async {
    if let Some(task)=&resume{let a=self.agents.get(task).await?;if a.provider!="codex"||a.workspace_id!=workspace["id"]{return Err("agent_workspace_mismatch".into())}if self.runtime.codex.lock().await.contains_key(&a.terminal_id){return Err("agent_already_running".into())}}
    let config=codex::mcp_config(&binary,&self.endpoint,&self.token_file,workspace["id"].as_str().ok_or("workspace id")?,terminal,&browser_token);let (events,mut rx)=super::event_queue::channel();let rpc=CodexRpc::start(&program,&env,&codex::overrides(&config),events).await?;self.runtime.codex.lock().await.insert(terminal.into(),rpc.clone());
    let agents=self.agents.clone();let terminal_id=terminal.to_string();let workspace_copy=workspace.clone();let title_rpc=rpc.clone();tokio::spawn(async move{let mut titled=std::collections::HashSet::new();while let Some(event)=rx.recv().await{
     if event["method"]=="neura/overflow"{let _=agents.codex_event(&terminal_id,&workspace_copy,&json!({"method":"neura/disconnected"})).await;let _=reconcile_codex(&agents,&title_rpc,&terminal_id,&workspace_copy).await;continue;}
     if let Some(task)=event["params"]["threadId"].as_str(){if agents.get(task).await.is_err(){let _=reconcile_codex(&agents,&title_rpc,&terminal_id,&workspace_copy).await;}}
     let _=agents.codex_event(&terminal_id,&workspace_copy,&event).await;if event["method"]=="turn/completed"&&event["params"]["turn"]["status"]=="completed"{if let Some(task)=event["params"]["threadId"].as_str(){if agents.get(task).await.is_ok()&&titled.insert(task.to_string()){let rpc=title_rpc.clone();let task=task.to_string();let cwd=workspace_copy["path"].as_str().unwrap_or("").to_string();tokio::spawn(async move{let _=codex::generate_title(rpc,task,cwd).await;});}}}}});
    let task:Option<String>=if choose_history{None}else{
     let mut params=json!({"cwd":workspace["path"],"approvalPolicy":"never","sandbox":"danger-full-access","config":{"mcp_servers.neuraos":config},"developerInstructions":codex::session_instructions()});if let Some(id)=&resume{params["threadId"]=json!(id);params["excludeTurns"]=json!(true);}
     let result=rpc.call(if resume.is_some(){"thread/resume"}else{"thread/start"},params).await?;let thread=&result["thread"];let id=thread["id"].as_str().ok_or("invalid Codex thread")?;
     if resume.is_none(){rpc.call("thread/inject_items",json!({"threadId":id,"items":[{"type":"message","role":"developer","content":[{"type":"input_text","text":format!("This Codex session is managed by neuraOS. Your neuraOS task ID is {id}. Its conversation can be inspected and directed from the neuraOS task tools and UI.")}]}]})).await?;}
     if !self.agents.register_codex(terminal,workspace,thread,parent).await?{return Err("agent_workspace_mismatch".into())}Some(id.into())
    };
    let mut args=vec!["resume".into()];if let Some(task)=&task{args.push(task.clone());}args.extend(["--remote".into(),rpc.endpoint.clone()]);
    if let (Some(task),Some(prompt))=(&task,prompt){self.agents.send(task,&prompt,"queue",None).await?;}
    Ok(LaunchSpec{program:program.clone(),args,env,agent_id:task})
   }.await
        } else {
            Err("invalid provider".into())
        };
        result
        }.await;
        drop(gate);
        cancelled.armed = false;
        if result.is_err() {
            if let Err(cleanup) = self.close(terminal).await {
                return Err(format!("{}; cleanup: {cleanup}", result.err().unwrap()));
            }
        }
        result
    }
    async fn check_support(&self, provider: &str, program: &str) -> Result<()> {
        let mut supported = self.supported.lock().await;
        if let Some(result) = supported.get(program) {
            return result.clone();
        }
        let result = async {
            let help = probe(program, "--help").await?;
            if provider == "codex" {
                if !help.contains("--remote") || !help.contains("app-server") {
                    return Err("codex_managed_unsupported".into());
                }
            } else {
                if !help.contains("--mcp-config")
                    || !help.contains("--append-system-prompt")
                    || !help.contains("--settings")
                {
                    return Err("claude_mcp_unsupported".into());
                }
                let version = probe(program, "--version").await?;
                let version = version.split_whitespace().next().unwrap_or("");
                let parts: Vec<u64> = version.split('.').map(|v| v.parse().unwrap_or(0)).collect();
                if parts.len() < 3 || (parts[0], parts[1], parts[2]) < (2, 1, 306) {
                    return Err("claude_channels_unsupported".into());
                }
            }
            Ok(())
        }
        .await;
        supported.insert(program.into(), result.clone());
        result
    }
    pub async fn channel(self: &Arc<Self>, terminal: &str) -> Result<Value> {
        let event = self.agents.channel(terminal).await?;
        if event["meta"]["kind"] == "probe" {
            let weak = Arc::downgrade(self);
            let terminal = terminal.to_string();
            tokio::spawn(async move {
                tokio::time::sleep(Duration::from_millis(60001)).await;
                if let Some(service) = weak.upgrade() {
                    let _ = service.agents.channel(&terminal).await;
                }
            });
        }
        Ok(event)
    }
    async fn hook_socket(self: &Arc<Self>, terminal: &str) -> Result<PathBuf> {
        let directory = super::socket_dir::create()?;
        let path = directory.join("activity.sock");
        let listener = match UnixListener::bind(&path) {
            Ok(listener) => listener,
            Err(error) => {
                let _ = std::fs::remove_dir(&directory);
                return Err(error.to_string());
            }
        };
        let weak = Arc::downgrade(self);
        let terminal_id = terminal.to_string();
        let task = tokio::spawn(async move {
            while let Ok((socket, _)) = listener.accept().await {
                let Some(service) = weak.upgrade() else { break };
                let terminal = terminal_id.clone();
                tokio::spawn(async move {
                    let mut line = String::new();
                    let read = tokio::time::timeout(
                        Duration::from_secs(5),
                        BufReader::new(socket.take(16385)).read_line(&mut line),
                    )
                    .await;
                    if !matches!(read, Ok(Ok(_))) || line.len() > 16384 {
                        return;
                    }
                    let Ok(event) = serde_json::from_str::<Value>(&line) else {
                        return;
                    };
                    if service.agents.claude_event(&terminal, &event).await == Ok(true) {
                        if let Some(path) = event["transcript_path"].as_str() {
                            let _ = service.monitor.observe(&terminal, path.into());
                        }
                    }
                });
            }
        });
        self.hooks
            .lock()
            .await
            .insert(terminal.into(), (directory, task));
        Ok(path)
    }
    pub async fn snapshot(&self) -> Result<Value> {
        let state = self
            .store
            .call("state", json!({}))
            .await
            .map_err(|e| e.to_string())?;
        let current: HashMap<String, String> = state["terminals"]
            .as_array()
            .into_iter()
            .flatten()
            // Legacy Claude records may have sessionId without agentId. Keep
            // the original HTTP contract: this map contains Claude sessions.
            .filter(|t| t["provider"] == "claude")
            .filter_map(|t| Some((t["id"].as_str()?.into(), t["sessionId"].as_str()?.into())))
            .collect();
        Ok(
            json!({"agents":self.agents.list().await,"revision":state["revision"],"currentSessionIds":current}),
        )
    }
    pub async fn close(self: &Arc<Self>, terminal: &str) -> Result<()> {
        let life = {
            let mut lifecycle = self.lifecycle.lock().unwrap();
            lifecycle
                .terminals
                .entry(terminal.to_owned())
                .or_default()
                .clone()
        };
        life.closing.store(true, Ordering::Release);
        let this = self.clone();
        let id = terminal.to_owned();
        let cleanup_life = life.clone();
        let result = self
            .cleanup
            .run(terminal, async move {
                let life = cleanup_life;
                let _gate = life.gate.lock().await;
                let result = this.cleanup_terminal(&id).await;
                if result.is_ok() {
                    let mut lifecycle = this.lifecycle.lock().unwrap();
                    if lifecycle
                        .terminals
                        .get(&id)
                        .is_some_and(|current| Arc::ptr_eq(current, &life))
                    {
                        lifecycle.terminals.remove(&id);
                    }
                }
                result
            })
            .await;
        // A duplicate may register after the worker removes its lifecycle entry
        // but before its completion is published. Retire that empty entry too.
        if result.is_ok() {
            let mut lifecycle = self.lifecycle.lock().unwrap();
            if lifecycle
                .terminals
                .get(terminal)
                .is_some_and(|current| Arc::ptr_eq(current, &life))
            {
                lifecycle.terminals.remove(terminal);
            }
        }
        result
    }
    async fn cleanup_terminal(&self, terminal: &str) -> Result<()> {
        let mut errors = Vec::new();
        self.credentials.lock().unwrap().remove(terminal);
        self.monitor.remove(terminal);
        if let Some((session, path)) = self.agents.observed_transcript(terminal).await {
            let read_session = session.clone();
            match tokio::task::spawn_blocking(move || {
                let mut reader = claude::CompletionReader::default();
                reader.read(&PathBuf::from(path), &read_session, i64::MAX)?;
                Ok::<_, String>(reader.title)
            })
            .await
            {
                Ok(Ok(Some((name, at)))) => {
                    if let Err(e) = self
                        .agents
                        .apply_claude_title(terminal, &session, &name, at)
                        .await
                    {
                        errors.push(format!("title: {e}"));
                    }
                }
                Ok(Ok(None)) => {}
                Ok(Err(e)) => errors.push(format!("title: {e}")),
                Err(e) => errors.push(format!("title task: {e}")),
            }
        }
        let hook = self.hooks.lock().await.remove(terminal);
        if let Some((directory, task)) = hook {
            task.abort();
            if let Err(e) = task.await {
                if !e.is_cancelled() {
                    errors.push(format!("hook task: {e}"));
                }
            }
            if let Err(e) = tokio::fs::remove_dir_all(directory).await {
                if e.kind() != std::io::ErrorKind::NotFound {
                    errors.push(format!("hook directory: {e}"));
                }
            }
        }
        let rpc = self.runtime.codex.lock().await.remove(terminal);
        if let Some(rpc) = rpc {
            if let Err(e) = rpc.close().await {
                errors.push(format!("Codex: {e}"));
            }
        }
        if let Err(e) = self.agents.close(terminal).await {
            errors.push(format!("agent: {e}"));
        }
        if errors.is_empty() {
            Ok(())
        } else {
            Err(errors.join("; "))
        }
    }
    pub async fn shutdown(self: &Arc<Self>) -> Result<()> {
        let mut ids = {
            let mut lifecycle = self.lifecycle.lock().unwrap();
            lifecycle.shutting_down = true;
            lifecycle.terminals.keys().cloned().collect::<Vec<_>>()
        };
        ids.extend(self.cleanup.ids());
        ids.extend(self.credentials.lock().unwrap().keys().cloned());
        ids.extend(self.hooks.lock().await.keys().cloned());
        ids.extend(self.runtime.codex.lock().await.keys().cloned());
        ids.sort();
        ids.dedup();
        let results = futures_util::future::join_all(ids.iter().map(|id| self.close(id))).await;
        self.monitor.close();
        let errors: Vec<_> = ids
            .into_iter()
            .zip(results)
            .filter_map(|(id, result)| result.err().map(|e| format!("{id}: {e}")))
            .collect();
        if errors.is_empty() {
            Ok(())
        } else {
            Err(format!("provider shutdown failed: {}", errors.join("; ")))
        }
    }
}
fn credential() -> String {
    format!(
        "{}{}",
        super::id().replace('-', ""),
        super::id().replace('-', "")
    )
}
fn equal(a: &str, b: &str) -> bool {
    if a.len() != b.len() {
        return false;
    }
    a.bytes()
        .zip(b.bytes())
        .fold(0u8, |diff, (a, b)| diff | (a ^ b))
        == 0
}
pub fn environment() -> HashMap<String, String> {
    let home = std::env::var("HOME").unwrap_or_default();
    HashMap::from([
        ("HOME".into(), home.clone()),
        ("USER".into(), std::env::var("USER").unwrap_or_default()),
        ("SHELL".into(), "/bin/zsh".into()),
        ("TERM".into(), "xterm-256color".into()),
        (
            "LANG".into(),
            std::env::var("LANG").unwrap_or("en_US.UTF-8".into()),
        ),
        (
            "PATH".into(),
            format!(
                "{home}/.local/bin:/opt/homebrew/bin:/usr/local/bin:{}",
                std::env::var("PATH").unwrap_or("/usr/bin:/bin".into())
            ),
        ),
    ])
}
pub async fn executable(provider: &str) -> Result<String> {
    if provider == "shell" {
        return Ok("/bin/zsh".into());
    }
    let override_key = match provider {
        "codex" => "NEURA_CODEX_PATH",
        "claude" => "NEURA_CLAUDE_PATH",
        _ => return Err("invalid provider".into()),
    };
    let paths = if let Ok(path) = std::env::var(override_key) {
        vec![PathBuf::from(path)]
    } else {
        environment()["PATH"]
            .split(':')
            .map(|path| PathBuf::from(path).join(provider))
            .collect()
    };
    use std::os::unix::fs::PermissionsExt;
    for path in paths {
        if let Ok(metadata) = tokio::fs::metadata(&path).await {
            if metadata.is_file() && metadata.permissions().mode() & 0o111 != 0 {
                if let Ok(path) = tokio::fs::canonicalize(path).await {
                    return Ok(path.to_string_lossy().into());
                }
            }
        }
    }
    Err("provider_missing".into())
}

async fn reconcile_codex(
    agents: &Agents,
    rpc: &CodexRpc,
    terminal: &str,
    workspace: &Value,
) -> Result<()> {
    let mut cursor = Value::Null;
    loop {
        let page = rpc
            .call("thread/loaded/list", json!({"limit":100,"cursor":cursor}))
            .await?;
        for task in page["data"].as_array().ok_or("invalid loaded threads")? {
            let Some(task) = task.as_str() else { continue };
            let result = rpc.call("thread/read", json!({"threadId":task})).await?;
            let thread = &result["thread"];
            if thread["ephemeral"] == true || thread["parentThreadId"].is_string() {
                continue;
            }
            if !agents.discover_codex(terminal, workspace, thread).await? {
                continue;
            }
            rpc.call("thread/resume",json!({"threadId":task,"excludeTurns":true,"developerInstructions":codex::session_instructions()})).await?;
            let history = rpc
                .call(
                    "thread/turns/list",
                    json!({"threadId":task,"limit":1,"itemsView":"full","sortDirection":"desc"}),
                )
                .await?;
            if let Some(turn) = history["data"].as_array().and_then(|rows| rows.first()) {
                if turn["status"] == "inProgress" {
                    agents.codex_event(terminal,workspace,&json!({"method":"turn/started","params":{"threadId":task,"turn":turn}})).await?;
                } else if matches!(
                    turn["status"].as_str(),
                    Some("completed" | "failed" | "interrupted")
                ) {
                    if let Some(items) = turn["items"].as_array() {
                        for item in items {
                            if item["type"] == "agentMessage" {
                                agents.codex_event(terminal,workspace,&json!({"method":"item/completed","params":{"threadId":task,"turnId":turn["id"],"item":item}})).await?;
                            }
                        }
                    }
                    agents.codex_event(terminal,workspace,&json!({"method":"turn/completed","params":{"threadId":task,"turn":turn}})).await?;
                }
            }
        }
        cursor = page["nextCursor"].clone();
        if cursor.is_null() {
            break;
        }
    }
    Ok(())
}

async fn probe(program: &str, arg: &str) -> Result<String> {
    use std::process::Stdio;
    let lease = crate::process_tree::reserve().await?;
    let child = tokio::process::Command::new(program)
        .arg(arg)
        .env(crate::process_tree::OWNER_ENV, lease.token())
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .process_group(0)
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| e.to_string())?;
    let mut child = crate::process_tree::OwnedChild::new(child, lease.clone());
    lease
        .attach(child.child_mut().id().ok_or("provider probe pid")?)
        .await?;
    let stdout = child
        .child_mut()
        .stdout
        .take()
        .ok_or("provider probe stdout")?;
    let result = tokio::time::timeout(Duration::from_secs(3), async {
        let read = async {
            let mut bytes = Vec::new();
            stdout
                .take(256 * 1024 + 1)
                .read_to_end(&mut bytes)
                .await
                .map_err(|e| e.to_string())?;
            if bytes.len() > 256 * 1024 {
                return Err("provider_probe_too_large".into());
            }
            Ok(bytes)
        };
        let wait = async {
            lease.wait_exit().await?;
            lease.stop().await?;
            child.child_mut().wait().await.map_err(|e| e.to_string())
        };
        let (bytes, status) = tokio::try_join!(read, wait)?;
        if !status.success() {
            return Err("provider_probe_failed".into());
        }
        Ok(String::from_utf8_lossy(&bytes).into_owned())
    })
    .await
    .map_err(|_| "provider_probe_timeout".to_string())
    .and_then(|result| result);
    let stopped = lease.stop().await;
    if result.is_err() {
        let _ = child.child_mut().kill().await;
    }
    stopped?;
    child.child_mut().wait().await.map_err(|e| e.to_string())?;
    let _ = child.into_inner();
    result
}

#[cfg(test)]
mod shutdown_tests {
    use super::*;
    #[tokio::test]
    async fn shutdown_attempts_every_terminal_and_aggregates_cleanup_errors() {
        let dir =
            std::env::temp_dir().join(format!("neura-provider-shutdown-{}", super::super::id()));
        std::fs::create_dir(&dir).unwrap();
        let (events, _) = tokio::sync::broadcast::channel(16);
        let store = StoreHandle::open(&dir.join("test.sqlite"), events)
            .await
            .unwrap();
        let pty = PtyRuntime::new(store.clone()).unwrap();
        let service = ProviderService::new(
            store.clone(),
            pty.clone(),
            "http://127.0.0.1:1".into(),
            dir.join("token").display().to_string(),
        )
        .await
        .unwrap();
        let mut sessions = Vec::new();
        for id in ["bad-one", "bad-two", "good"] {
            let session = super::super::id();
            sessions.push(session.clone());
            let path = dir.join(id);
            if id == "good" {
                std::fs::create_dir(&path).unwrap();
            } else {
                std::fs::write(&path, b"not a directory").unwrap();
            }
            service
                .credentials
                .lock()
                .unwrap()
                .insert(id.into(), ("channel".into(), "browser".into()));
            service
                .hooks
                .lock()
                .await
                .insert(id.into(), (path, tokio::spawn(std::future::pending())));
            // Register a real agent so failure of hook cleanup cannot skip
            // interruption/persistence for the same terminal.
            service
                .agents
                .prepare_claude(
                    json!({"id":"w","path":dir,"name":"fixture"}),
                    id,
                    None,
                    None,
                    None,
                )
                .await
                .unwrap();
            assert!(service
                .agents
                .claude_event(
                    id,
                    &json!({"hook_event_name":"SessionStart","session_id":session})
                )
                .await
                .unwrap());
        }
        let error = service.shutdown().await.unwrap_err();
        assert!(error.contains("bad-one:"), "{error}");
        assert!(error.contains("bad-two:"), "{error}");
        assert!(!dir.join("good").exists());
        assert!(service.hooks.lock().await.is_empty());
        assert!(service.credentials.lock().unwrap().is_empty());
        for session in sessions {
            let row = store.get("agents", &session).await.unwrap().unwrap();
            assert_eq!(row["status"], "interrupted");
        }
        // A second shutdown must still report prior failed cleanup, not success
        // inferred from maps already emptied by the first shutdown.
        assert_eq!(service.shutdown().await.unwrap_err(), error);
        pty.shutdown().await.unwrap();
    }
    #[tokio::test]
    async fn shutdown_waits_for_inflight_close_after_resource_maps_are_empty() {
        let dir =
            std::env::temp_dir().join(format!("neura-provider-close-race-{}", super::super::id()));
        std::fs::create_dir(&dir).unwrap();
        let (events, _) = tokio::sync::broadcast::channel(16);
        let store = StoreHandle::open(&dir.join("test.sqlite"), events)
            .await
            .unwrap();
        let pty = PtyRuntime::new(store.clone()).unwrap();
        let service = ProviderService::new(
            store,
            pty.clone(),
            "http://127.0.0.1:1".into(),
            dir.join("token").display().to_string(),
        )
        .await
        .unwrap();
        let life = Arc::new(TerminalLife::default());
        service
            .lifecycle
            .lock()
            .unwrap()
            .terminals
            .insert("slow".into(), life.clone());
        let gate = life.gate.lock().await;
        let s = service.clone();
        let first = tokio::spawn(async move { s.close("slow").await });
        tokio::time::timeout(Duration::from_secs(1), async {
            while !life.closing.load(Ordering::Acquire) {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        let s = service.clone();
        let mut shutdown = tokio::spawn(async move { s.shutdown().await });
        assert!(
            tokio::time::timeout(Duration::from_millis(30), &mut shutdown)
                .await
                .is_err()
        );
        first.abort();
        let _ = first.await; // shared cleanup survives caller cancellation
        drop(gate);
        shutdown.await.unwrap().unwrap();
        assert!(service.lifecycle.lock().unwrap().terminals.is_empty());
        pty.shutdown().await.unwrap();
    }
}

#[cfg(test)]
mod hook_close_race_tests {
    use super::*;
    struct SlowDrop {
        entered: std::sync::mpsc::Sender<()>,
        release: std::sync::mpsc::Receiver<()>,
    }
    impl Drop for SlowDrop {
        fn drop(&mut self) {
            let _ = self.entered.send(());
            let _ = self.release.recv_timeout(Duration::from_secs(3));
        }
    }
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn removed_hook_is_not_completed_close_and_shutdown_waits_for_its_drop() {
        let dir =
            std::env::temp_dir().join(format!("neura-hook-close-race-{}", super::super::id()));
        std::fs::create_dir(&dir).unwrap();
        let (events, _) = tokio::sync::broadcast::channel(16);
        let store = StoreHandle::open(&dir.join("test.sqlite"), events)
            .await
            .unwrap();
        let pty = PtyRuntime::new(store.clone()).unwrap();
        let service = ProviderService::new(
            store,
            pty.clone(),
            "http://127.0.0.1:1".into(),
            dir.join("token").display().to_string(),
        )
        .await
        .unwrap();
        let hook_dir = dir.join("hook");
        std::fs::create_dir(&hook_dir).unwrap();
        let (entered_tx, entered_rx) = std::sync::mpsc::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        let (ready_tx, ready) = tokio::sync::oneshot::channel();
        let hook = tokio::spawn(async move {
            let _slow = SlowDrop {
                entered: entered_tx,
                release: release_rx,
            };
            let _ = ready_tx.send(());
            std::future::pending::<()>().await;
        });
        ready.await.unwrap();
        service
            .credentials
            .lock()
            .unwrap()
            .insert("slow".into(), ("channel".into(), "browser".into()));
        service
            .hooks
            .lock()
            .await
            .insert("slow".into(), (hook_dir.clone(), hook));
        let s = service.clone();
        let first = tokio::spawn(async move { s.close("slow").await });
        tokio::task::spawn_blocking(move || entered_rx.recv_timeout(Duration::from_secs(1)))
            .await
            .unwrap()
            .unwrap();
        assert!(service.hooks.lock().await.is_empty());
        assert!(service.credentials.lock().unwrap().is_empty());
        assert!(hook_dir.exists());
        let s = service.clone();
        let mut duplicate = tokio::spawn(async move { s.close("slow").await });
        tokio::time::timeout(Duration::from_secs(1), service.close("other"))
            .await
            .unwrap()
            .unwrap();
        let s = service.clone();
        let mut shutdown = tokio::spawn(async move { s.shutdown().await });
        assert!(
            tokio::time::timeout(Duration::from_millis(30), &mut duplicate)
                .await
                .is_err()
        );
        assert!(
            tokio::time::timeout(Duration::from_millis(30), &mut shutdown)
                .await
                .is_err()
        );
        release_tx.send(()).unwrap();
        first.await.unwrap().unwrap();
        duplicate.await.unwrap().unwrap();
        shutdown.await.unwrap().unwrap();
        assert!(!hook_dir.exists());
        pty.shutdown().await.unwrap();
    }
}
