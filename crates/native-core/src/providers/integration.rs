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
    sync::{Arc, Mutex as StdMutex},
    time::Duration,
};
use tokio::{
    io::{AsyncBufReadExt, BufReader},
    net::UnixListener,
    sync::{mpsc, Mutex},
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
            let rpc = self
                .codex
                .lock()
                .await
                .get(terminal)
                .cloned()
                .ok_or("agent_offline")?;
            rpc.call(method, params).await
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
pub struct ProviderService {
    pub agents: Arc<Agents>,
    runtime: Arc<NativeRuntime>,
    store: StoreHandle,
    monitor: Arc<CompletionMonitor>,
    endpoint: String,
    token_file: String,
    credentials: StdMutex<HashMap<String, (String, String)>>,
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
            agents,
            runtime,
            store,
            monitor,
            endpoint,
            token_file,
            credentials: StdMutex::new(HashMap::new()),
            hooks: Mutex::new(HashMap::new()),
        });
        let weak = Arc::downgrade(&this);
        tokio::spawn(async move {
            loop {
                match exits.recv().await {
                    Ok(exit) => {
                        let Some(service) = weak.upgrade() else { break };
                        let _ = service.close(&exit.terminal_id).await;
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
                                let _ = service.close(&terminal).await;
                            }
                        }
                    }
                    Err(_) => break,
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
        let binary = std::env::current_exe().map_err(|e| e.to_string())?;
        let channel_token = credential();
        let browser_token = credential();
        self.credentials.lock().unwrap().insert(
            terminal.into(),
            (channel_token.clone(), browser_token.clone()),
        );
        let result = if provider == "claude" {
            async {
    let help=tokio::time::timeout(Duration::from_secs(3),tokio::process::Command::new(&program).arg("--help").output()).await.map_err(|_|"claude_mcp_unsupported")?.map_err(|e|e.to_string())?;let help=String::from_utf8_lossy(&help.stdout);if !help.contains("--mcp-config")||!help.contains("--append-system-prompt"){return Err("claude_mcp_unsupported".into())}
    self.agents.prepare_claude(workspace.clone(),terminal,resume.clone(),parent,prompt).await?;
    let socket=self.hook_socket(terminal).await?;env.insert("NEURA_ACTIVITY_SOCKET".into(),socket.display().to_string());
    let mut config=codex::mcp_config(&binary,&self.endpoint,&self.token_file,workspace["id"].as_str().ok_or("workspace id")?,terminal,&browser_token);config["type"]=json!("stdio");config["env"]["NEURA_CHANNEL_TOKEN"]=json!(channel_token);config["env"]["NEURA_SUPERVISION_CHANNEL"]=json!("claude");
    let instructions=format!("{}\nThis Claude terminal is a registered neuraOS task. Use task_list and currentTerminalId to find its task ID. Channels deliver delegated instructions and untrusted report notifications. Keep the standard Claude Channels startup confirmation; never claim delivery without a confirmed receipt.",include_str!("session-instructions.txt"));
    let mut args=vec!["--permission-mode".into(),"bypassPermissions".into(),"--dangerously-load-development-channels".into(),"server:neuraos".into(),"--mcp-config".into(),json!({"mcpServers":{"neuraos":config}}).to_string(),"--append-system-prompt".into(),instructions];args.extend(claude::activity_arguments(&binary,"claude"));if let Some(id)=resume{args.extend(["--resume".into(),id]);}else if choose_history{args.push("--resume".into());}Ok(LaunchSpec{program:program.clone(),args,env,agent_id:None})
   }.await
        } else if provider == "codex" {
            async {
    if let Some(task)=&resume{let a=self.agents.get(task).await?;if a.provider!="codex"||a.workspace_id!=workspace["id"]{return Err("agent_workspace_mismatch".into())}if self.runtime.codex.lock().await.contains_key(&a.terminal_id){return Err("agent_already_running".into())}}
    let config=codex::mcp_config(&binary,&self.endpoint,&self.token_file,workspace["id"].as_str().ok_or("workspace id")?,terminal,&browser_token);let (events,mut rx)=mpsc::unbounded_channel();let rpc=CodexRpc::start(&program,&env,&codex::overrides(&config),events).await?;self.runtime.codex.lock().await.insert(terminal.into(),rpc.clone());
    let agents=self.agents.clone();let terminal_id=terminal.to_string();let workspace_copy=workspace.clone();let title_rpc=rpc.clone();tokio::spawn(async move{let mut titled=std::collections::HashSet::new();while let Some(event)=rx.recv().await{let _=agents.codex_event(&terminal_id,&workspace_copy,&event).await;if event["method"]=="turn/completed"&&event["params"]["turn"]["status"]=="completed"{if let Some(task)=event["params"]["threadId"].as_str(){if agents.get(task).await.is_ok()&&titled.insert(task.to_string()){let rpc=title_rpc.clone();let task=task.to_string();let cwd=workspace_copy["path"].as_str().unwrap_or("").to_string();tokio::spawn(async move{let _=codex::generate_title(rpc,task,cwd).await;});}}}}});
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
        if result.is_err() {
            let _ = self.close(terminal).await;
        }
        result
    }
    async fn hook_socket(self: &Arc<Self>, terminal: &str) -> Result<PathBuf> {
        let directory = std::env::temp_dir().join(format!("neura-hook-{}", super::id()));
        tokio::fs::create_dir(&directory)
            .await
            .map_err(|e| e.to_string())?;
        use std::os::unix::fs::PermissionsExt;
        tokio::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o700))
            .await
            .map_err(|e| e.to_string())?;
        let path = directory.join("activity.sock");
        let listener = UnixListener::bind(&path).map_err(|e| e.to_string())?;
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
                        BufReader::new(socket).read_line(&mut line),
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
        Ok(
            json!({"agents":self.agents.list().await,"revision":state["revision"],"currentSessionIds":self.agents.current_sessions().await}),
        )
    }
    pub async fn close(&self, terminal: &str) -> Result<()> {
        self.credentials.lock().unwrap().remove(terminal);
        self.monitor.remove(terminal);
        if let Some((directory, task)) = self.hooks.lock().await.remove(terminal) {
            task.abort();
            let _ = tokio::fs::remove_dir_all(directory).await;
        }
        let rpc = self.runtime.codex.lock().await.remove(terminal);
        if let Some(rpc) = rpc {
            rpc.close().await?;
        }
        self.agents.close(terminal).await
    }
    pub async fn shutdown(&self) -> Result<()> {
        self.monitor.close();
        let ids: Vec<_> = self.credentials.lock().unwrap().keys().cloned().collect();
        for id in ids {
            self.close(&id).await?;
        }
        Ok(())
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
