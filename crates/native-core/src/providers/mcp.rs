use super::Result;
use futures_util::StreamExt;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{sync::Arc, time::Duration};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    sync::{watch, Mutex},
    task::JoinSet,
};
use tokio_tungstenite::tungstenite::{client::IntoClientRequest, http::HeaderValue};

fn catalog() -> &'static Vec<Value> {
    static TOOLS: std::sync::OnceLock<Vec<Value>> = std::sync::OnceLock::new();
    TOOLS.get_or_init(|| {
        serde_json::from_str(include_str!("tools.json")).expect("native MCP catalog")
    })
}

#[derive(Clone)]
struct Client {
    http: reqwest::Client,
    endpoint: reqwest::Url,
    token: String,
    terminal: String,
    workspace: String,
    channel_token: String,
    browser_token: String,
    changes: watch::Receiver<u64>,
    channel_changes: watch::Receiver<u64>,
}
impl Client {
    async fn request(
        &self,
        path: &str,
        body: Option<Value>,
        header: Option<(&str, &str)>,
    ) -> Result<Value> {
        let url = self.endpoint.join(path).map_err(|e| e.to_string())?;
        let mut request = if let Some(body) = body {
            self.http.post(url).json(&body)
        } else {
            self.http.get(url)
        }
        .bearer_auth(&self.token);
        if let Some((key, value)) = header {
            request = request.header(key, value);
        }
        let response = request.send().await.map_err(|e| e.to_string())?;
        let success = response.status().is_success();
        let value: Value = response.json().await.map_err(|e| e.to_string())?;
        if !success {
            return Err(value.to_string());
        }
        Ok(value)
    }
    async fn command(&self, operation: &Value, command: Value) -> Result<Value> {
        self.request(
            "/v1/commands",
            Some(json!({"operationId":operation,"command":command})),
            None,
        )
        .await
    }
    async fn deletion_job(&self, id: &str, wait_ms: u64, after: Option<u64>) -> Result<Value> {
        if !crate::contracts::valid_uuid(id) || wait_ms > 25_000 {
            return Err("invalid_deletion_status_options".into());
        }
        let mut path = format!("/v1/workspace-deletions/{id}?waitMs={wait_ms}");
        if let Some(revision) = after {
            path.push_str(&format!("&afterRevision={revision}"));
        }
        let job = tokio::time::timeout(
            Duration::from_millis(wait_ms) + Duration::from_secs(2),
            self.request(&path, None, None),
        )
        .await
        .map_err(|_| json!({"error":"deletion_status_timeout","jobId":id}).to_string())??;
        validate_deletion_job(&job, Some(id), None)?;
        Ok(job)
    }
    async fn await_deletion(
        &self,
        mut job: Value,
        workspace: &str,
        budget: Duration,
    ) -> Result<Value> {
        // An idempotent start can return an older job: pin its returned ID, not operationId.
        validate_deletion_job(&job, None, Some(workspace))?;
        let id = job["id"].as_str().unwrap().to_owned();
        let deadline = tokio::time::Instant::now() + budget;
        while matches!(job["status"].as_str(), Some("queued" | "running")) {
            let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
            if remaining.is_zero() {
                break;
            }
            let next = tokio::time::timeout(
                remaining,
                self.deletion_job(
                    &id,
                    (remaining.as_millis() as u64).min(25_000),
                    job["revision"].as_u64(),
                ),
            )
            .await
            .map_err(|_| "deletion_status_timeout".to_string())
            .and_then(|v| v)
            .and_then(|next| {
                validate_deletion_job(&next, Some(&id), Some(workspace))?;
                Ok(next)
            });
            match next {
                Ok(next) => job = next,
                Err(error) => {
                    let mut pending = self.deletion_result(job).await?;
                    pending["statusError"] = json!(error);
                    return Ok(pending);
                }
            }
        }
        self.deletion_result(job).await
    }
    async fn deletion_result(&self, job: Value) -> Result<Value> {
        validate_deletion_job(&job, None, None)?;
        // Proof has its own short budget, including when status transport failed.
        let proof = tokio::time::timeout(
            Duration::from_secs(2),
            self.request("/v1/state", None, None),
        )
        .await
        .map_err(|_| "deletion_proof_timeout".to_string())
        .and_then(|v| v);
        let present = proof.as_ref().ok().and_then(|state| {
            state["workspaces"]
                .as_array()
                .map(|rows| rows.iter().any(|w| w["id"] == job["workspaceId"]))
        });
        let succeeded = job["status"] == "succeeded";
        let verified = succeeded && job["verifiedAbsent"] == true && present == Some(false);
        let mut result = json!({"accepted":true,"completed":verified,"jobId":job["id"],"workspaceId":job["workspaceId"],"status":job["status"],"job":job,"workspacePresent":present,"verifiedAbsent":verified});
        if let Err(error) = proof {
            result["proofError"] = json!(error);
        }
        if result["status"] == "failed" {
            return Err(result.to_string());
        }
        if succeeded && !verified {
            return Err(json!({"error":"cleanup_unconfirmed","result":result}).to_string());
        }
        Ok(result)
    }
    async fn context(&self, a: &Value, workspace: &str) -> Result<Value> {
        let (state, list) = tokio::try_join!(
            self.request("/v1/state", None, None),
            self.request("/v1/agents", None, None)
        )?;
        let empty = vec![];
        let ws = state["workspaces"]
            .as_array()
            .unwrap_or(&empty)
            .iter()
            .find(|w| w["id"] == workspace);
        let project_id = a.get("projectId").or_else(|| ws.map(|w| &w["projectId"]));
        let project = state["projects"]
            .as_array()
            .unwrap_or(&empty)
            .iter()
            .find(|p| Some(&p["id"]) == project_id);
        let terminal = state["terminals"]
            .as_array()
            .unwrap_or(&empty)
            .iter()
            .find(|t| t["id"] == self.terminal);
        let agents = list["agents"].as_array().unwrap_or(&empty);
        let caller = terminal.and_then(|t| {
            agents
                .iter()
                .find(|a| a["id"] == t["agentId"] && a["terminalId"] == t["id"])
        });
        let resumed = agents
            .iter()
            .find(|r| a["resumeTaskId"].is_string() && r["id"] == a["resumeTaskId"]);
        let mut prior = project
            .and_then(|p| p["worktreeStartup"].as_array())
            .cloned()
            .unwrap_or_default();
        prior.retain(|p| p == "codex" || p == "claude");
        prior.sort_by_key(Value::to_string);
        prior.dedup();
        let provider = a
            .get("provider")
            .cloned()
            .or_else(|| resumed.map(|r| r.get("provider").cloned().unwrap_or(json!("codex"))))
            .or_else(|| project.and_then(|p| p.get("defaultDelegationProvider").cloned()))
            .unwrap_or_else(|| {
                if prior.len() == 1 {
                    prior[0].clone()
                } else {
                    json!("codex")
                }
            });
        let mut result = json!({"provider":provider});
        if let Some(parent) = a.get("parentTaskId").or_else(|| caller.map(|c| &c["id"])) {
            result["parentTaskId"] = parent.clone();
        }
        Ok(result)
    }
    async fn startup(&self, mut terminal: Value) -> Value {
        terminal["terminalId"] = terminal["id"].clone();
        terminal["taskId"] = terminal["agentId"].clone();
        if terminal["provider"] != "claude" {
            return terminal;
        }
        let mut channel = "unknown".to_string();
        let mut agent = None;
        if let Ok(list) = self.request("/v1/agents", None, None).await {
            let current = &list["currentSessionIds"][terminal["id"].as_str().unwrap_or("")];
            agent = list["agents"]
                .as_array()
                .and_then(|agents| {
                    agents
                        .iter()
                        .find(|a| a["id"] == *current && a["terminalId"] == terminal["id"])
                })
                .cloned();
            if list["currentSessionIds"].is_object() {
                channel = agent
                    .as_ref()
                    .and_then(|a| a["channelState"].as_str())
                    .unwrap_or("pending")
                    .into();
            }
        }
        terminal["registrationPending"] = json!(channel != "connected");
        terminal["channelState"] = json!(channel);
        if let Some(agent) = &agent {
            terminal["taskId"] = agent["id"].clone();
            terminal["agentId"] = agent["id"].clone();
        }
        if channel != "connected" {
            terminal["recovery"]=json!("Claude has started but Channels receipt is not confirmed. Inspect this terminal and its standard Channels confirmation, MCP connection and account/organization policy. Check task_list for this terminalId; confirm the Channels startup prompt in that terminal. If unavailable, cancel the queued instruction with task_instruction before explicitly retrying another provider; never claim delivery or auto-switch providers.");
        }
        terminal
    }
    async fn call(&self, name: &str, a: Value) -> Result<Value> {
        let operation = &a["operationId"];
        if catalog().iter().any(|t| {
            t["name"] == name && t["inputSchema"]["properties"].get("operationId").is_some()
        }) && !operation.as_str().is_some_and(crate::contracts::valid_uuid)
        {
            return Err(json!({"error":"invalid_request","field":"operationId","reason":if a.get("operationId").is_none(){"required"}else{"expected_uuid"}}).to_string());
        }
        match name {
            "workspace_list" => {
                let s = self.request("/v1/state", None, None).await?;
                Ok(
                    json!({"currentWorkspaceId":self.workspace,"projects":s["projects"],"workspaces":s["workspaces"]}),
                )
            }
            "workspace_create" => {
                let mut c = a.clone();
                c["type"] = json!("workspace.create");
                c["skipStartup"] = json!(true);
                c.as_object_mut().unwrap().remove("operationId");
                self.command(operation, c).await
            }
            "workspace_delete" => {
                if self.workspace.is_empty() || a["workspaceId"] == self.workspace {
                    return Err("Cannot delete the caller workspace".into());
                }
                let state = tokio::time::timeout(Duration::from_secs(15), self.request("/v1/state", None, None))
                    .await.map_err(|_| json!({"error":"deletion_feature_timeout","operationId":operation,"workspaceId":a["workspaceId"],"startRequestSent":false,"completed":false,"recovery":"Inspect workspace state; retry only the identical request with the same operationId."}).to_string())??;
                if state["features"].as_array().is_some_and(|features| {
                    features
                        .iter()
                        .any(|feature| feature == "workspace.delete.jobs")
                }) {
                    let accepted = tokio::time::timeout(Duration::from_secs(15), self.command(operation,json!({"type":"workspace.delete.start","workspaceId":a["workspaceId"],"stopTerminals":true,"discardChanges":false,"cleanup":{"callerWorkspaceId":self.workspace,"expectedHead":a["expectedHead"],"mergedPR":a["mergedPR"]}})))
                        .await.map_err(|_| json!({"error":"deletion_start_uncertain","operationId":operation,"workspaceId":a["workspaceId"],"outcome":"unknown","completed":false,"recovery":"The start request timed out and may still be accepted. Inspect workspace state; retry only the identical request with the same operationId to recover the existing job. Do not start a replacement operation or infer a jobId from operationId."}).to_string())??;
                    return self
                        .await_deletion(
                            accepted["job"].clone(),
                            a["workspaceId"].as_str().ok_or("invalid_workspace_id")?,
                            Duration::from_secs(25),
                        )
                        .await;
                }
                let result=self.command(operation,json!({"type":"workspace.delete","workspaceId":a["workspaceId"],"stopTerminals":true,"discardChanges":false,"cleanup":{"callerWorkspaceId":self.workspace,"expectedHead":a["expectedHead"],"mergedPR":a["mergedPR"]}})).await;
                let present = self
                    .request("/v1/state", None, None)
                    .await
                    .ok()
                    .and_then(|s| {
                        s["workspaces"]
                            .as_array()
                            .map(|w| w.iter().any(|w| w["id"] == a["workspaceId"]))
                    });
                match result {
                    Err(error) => {
                        Err(json!({"error":error,"workspacePresent":present}).to_string())
                    }
                    Ok(mut result) => {
                        if present != Some(false) {
                            return Err("Cleanup could not be confirmed".into());
                        }
                        result["verifiedAbsent"] = json!(true);
                        Ok(result)
                    }
                }
            }
            "workspace_deletion_status" => {
                let id = a["jobId"]
                    .as_str()
                    .ok_or("invalid_deletion_status_options")?;
                let wait = match a.get("waitMs") {
                    None => 0,
                    Some(value) => value.as_u64().ok_or("invalid_deletion_status_options")?,
                };
                let after = match a.get("afterRevision") {
                    None => None,
                    Some(value) => Some(value.as_u64().ok_or("invalid_deletion_status_options")?),
                };
                self.deletion_result(self.deletion_job(id, wait, after).await?)
                    .await
            }
            "task_list" => {
                let mut url = self
                    .endpoint
                    .join("/v1/agents")
                    .map_err(|e| e.to_string())?;
                if !a.as_object().ok_or("invalid arguments")?.is_empty() {
                    url.query_pairs_mut().append_pair("options", &a.to_string());
                }
                let path = format!(
                    "{}{}",
                    url.path(),
                    url.query().map(|q| format!("?{q}")).unwrap_or_default()
                );
                let mut s = self.request(&path, None, None).await?;
                s["currentWorkspaceId"] = json!(self.workspace);
                s["currentTerminalId"] = json!(self.terminal);
                Ok(s)
            }
            "task_read" => {
                let mut url = self
                    .endpoint
                    .join(&format!("/v1/agents/{}", string(&a, "taskId")?))
                    .map_err(|e| e.to_string())?;
                for key in ["cursor", "mode"] {
                    if let Some(value) = a[key].as_str() {
                        url.query_pairs_mut().append_pair(key, value);
                    }
                }
                self.request(
                    &format!(
                        "{}{}",
                        url.path(),
                        url.query().map(|q| format!("?{q}")).unwrap_or_default()
                    ),
                    None,
                    None,
                )
                .await
            }
            "task_start" => {
                let mut c = self.context(&a, string(&a, "workspaceId")?).await?;
                c["type"] = json!("terminal.open");
                for key in ["workspaceId", "prompt"] {
                    if let Some(v) = a.get(key) {
                        c[key] = v.clone();
                    }
                }
                if let Some(v) = a.get("resumeTaskId") {
                    c["resumeId"] = v.clone();
                }
                Ok(self.startup(self.command(operation, c).await?).await)
            }
            "task_spawn" => {
                let mut c = json!({"type":"workspace.create","projectId":a["projectId"],"skipStartup":true});
                for key in ["name", "baseRef"] {
                    if let Some(v) = a.get(key) {
                        c[key] = v.clone();
                    }
                }
                let mut workspace = self.command(operation, c).await?;
                if workspace["setup"].is_object() {
                    let state = self.request("/v1/state", None, None).await?;
                    if let Some(w) = state["workspaces"]
                        .as_array()
                        .and_then(|w| w.iter().find(|w| w["id"] == workspace["id"]))
                    {
                        workspace = w.clone();
                    }
                    if workspace["setup"]["status"] == "running" {
                        return Ok(
                            json!({"workspace":workspace,"taskId":null,"terminalId":null,"setupPending":true,"recovery":"Inspect workspace_list and retry the same operationId after setup completes."}),
                        );
                    }
                    if workspace["setup"]["status"] == "failed" {
                        return Ok(
                            json!({"workspace":workspace,"taskId":null,"terminalId":null,"startupError":workspace["setup"]["error"],"recovery":"Inspect setup, retry setup in the app, then retry the same operationId."}),
                        );
                    }
                }
                let result = async {
                    let mut c = self.context(&a, string(&workspace, "id")?).await?;
                    c["type"] = json!("terminal.open");
                    c["workspaceId"] = workspace["id"].clone();
                    c["prompt"] = a["prompt"].clone();
                    self.command(&json!(derived(string(&a, "operationId")?)), c)
                        .await
                }
                .await;
                Ok(match result {
                    Ok(t) => {
                        let terminal = self.startup(t).await;
                        json!({"workspace":workspace,"taskId":terminal["taskId"],"terminalId":terminal["terminalId"],"terminal":terminal})
                    }
                    Err(e) => {
                        json!({"workspace":workspace,"taskId":null,"terminalId":null,"startupError":e,"recovery":"Worktree remains. Inspect task_list before retrying task_start."})
                    }
                })
            }
            "channel_ack" => {
                self.request(
                    &format!("/v1/claude/{}/channel-ack", self.terminal),
                    Some(json!({"nonce":a["nonce"]})),
                    Some(("x-neura-channel-token", &self.channel_token)),
                )
                .await
            }
            "task_wait" => {
                let after = a["after"].as_u64().ok_or("Invalid revision")?;
                let deadline = tokio::time::Instant::now() + Duration::from_secs(25);
                let mut changes = self.changes.clone();
                loop {
                    changes.borrow_and_update();
                    let snapshot = self.request("/v1/agents", None, None).await?;
                    if snapshot["revision"].as_u64().unwrap_or(0) != after
                        || tokio::time::Instant::now() >= deadline
                    {
                        return Ok(snapshot);
                    }
                    if tokio::time::timeout_at(deadline, changes.changed())
                        .await
                        .is_err()
                    {
                        return self.request("/v1/agents", None, None).await;
                    }
                }
            }
            "task_instruction" | "task_report" | "task_ack" | "task_send" | "task_interrupt"
            | "task_respond" | "task_watch" => {
                let mut c = a.clone();
                let map = c.as_object_mut().ok_or("invalid arguments")?;
                map.remove("operationId");
                map.remove("taskId");
                map.remove("supervisorId");
                c["type"] = json!(match name {
                    "task_instruction" => "agent.instruction",
                    "task_report" => "agent.report",
                    "task_ack" => "agent.ack",
                    "task_send" => "agent.send",
                    "task_interrupt" => "agent.interrupt",
                    "task_respond" => "agent.respond",
                    _ => "agent.watch",
                });
                c["agentId"] = a[if name == "task_watch" {
                    "supervisorId"
                } else {
                    "taskId"
                }]
                .clone();
                if name == "task_report" || name == "task_instruction" {
                    c["sourceTerminalId"] = json!(self.terminal);
                }
                self.command(operation, c).await
            }
            _ if name.starts_with("browser_") => {
                if self.terminal.is_empty()
                    || self.browser_token.is_empty()
                    || a.get("action").is_some()
                {
                    return Err("Invalid browser caller or action".into());
                }
                let mut command = a;
                command["action"] = json!(&name[8..]);
                self.request(
                    "/v1/browser/call",
                    Some(json!({"terminalId":self.terminal,"command":command})),
                    Some(("x-neura-browser-token", &self.browser_token)),
                )
                .await
            }
            _ => Err("Unknown tool".into()),
        }
    }
}
fn validate_deletion_job(job: &Value, id: Option<&str>, workspace: Option<&str>) -> Result<()> {
    if !job["id"].as_str().is_some_and(crate::contracts::valid_uuid)
        || !job["workspaceId"]
            .as_str()
            .is_some_and(crate::contracts::valid_uuid)
        || !matches!(
            job["status"].as_str(),
            Some("queued" | "running" | "succeeded" | "failed")
        )
        || id.is_some_and(|id| job["id"] != id)
        || workspace.is_some_and(|workspace| job["workspaceId"] != workspace)
    {
        return Err(json!({"error":"invalid_deletion_job","expectedJobId":id,"expectedWorkspaceId":workspace,"job":job}).to_string());
    }
    Ok(())
}
fn string<'a>(v: &'a Value, key: &str) -> Result<&'a str> {
    v[key].as_str().ok_or_else(|| format!("missing {key}"))
}
fn derived(operation: &str) -> String {
    let bytes = Sha256::digest(format!("neura-terminal:{operation}"));
    let h = bytes.iter().map(|b| format!("{b:02x}")).collect::<String>();
    format!(
        "{}-{}-4{}-a{}-{}",
        &h[..8],
        &h[8..12],
        &h[13..16],
        &h[17..20],
        &h[20..32]
    )
}
async fn output(out: &Arc<Mutex<tokio::io::Stdout>>, value: Value) -> Result<()> {
    let mut out = out.lock().await;
    out.write_all(format!("{value}\n").as_bytes())
        .await
        .map_err(|e| e.to_string())?;
    out.flush().await.map_err(|e| e.to_string())
}
pub async fn run() -> Result<()> {
    let endpoint = reqwest::Url::parse(
        &std::env::var("NEURA_SUPERVISION_URL").unwrap_or("http://127.0.0.1:4318".into()),
    )
    .map_err(|e| e.to_string())?;
    if endpoint.scheme() != "http" || endpoint.host_str() != Some("127.0.0.1") {
        return Err("A loopback endpoint is required".into());
    }
    let token = tokio::fs::read_to_string(
        std::env::var("NEURA_SUPERVISION_TOKEN_FILE").map_err(|e| e.to_string())?,
    )
    .await
    .map_err(|e| e.to_string())?
    .trim()
    .to_string();
    let (changes, rx) = watch::channel(0u64);
    let (channel_changes, channel_rx) = watch::channel(0u64);
    let env = |key| std::env::var(key).unwrap_or_default();
    let client = Client {
        http: reqwest::Client::builder()
            .timeout(Duration::from_secs(250))
            .build()
            .map_err(|e| e.to_string())?,
        endpoint,
        token,
        terminal: env("NEURA_SUPERVISION_TERMINAL"),
        workspace: env("NEURA_SUPERVISION_WORKSPACE"),
        channel_token: env("NEURA_CHANNEL_TOKEN"),
        browser_token: env("NEURA_BROWSER_TOKEN"),
        changes: rx,
        channel_changes: channel_rx,
    };
    let out = Arc::new(Mutex::new(tokio::io::stdout()));
    let mut tasks = JoinSet::new();
    let (initialized, mut ready) = watch::channel(false);
    let channel = env("NEURA_SUPERVISION_CHANNEL") == "claude";
    let c = client.clone();
    tasks.spawn(async move {
        let mut retry = Duration::from_millis(250);
        loop {
            let mut url = c.endpoint.join("/v1/stream").unwrap();
            let _ = url.set_scheme("ws");
            let mut request = url.as_str().into_client_request().unwrap();
            request.headers_mut().insert(
                "Authorization",
                HeaderValue::from_str(&format!("Bearer {}", c.token)).unwrap(),
            );
            if let Ok(Ok((mut socket, _))) = tokio::time::timeout(
                Duration::from_secs(10),
                tokio_tungstenite::connect_async(request),
            )
            .await
            {
                while let Some(Ok(message)) = socket.next().await {
                    if let Ok(text) = message.to_text() {
                        if let Ok(e) = serde_json::from_str::<Value>(text) {
                            if e["type"] == "ready" || e["type"] == "changed" && e["state"] == true
                            {
                                retry = Duration::from_millis(250);
                                changes.send_modify(|v| *v = v.wrapping_add(1));
                                if e["type"] == "ready"
                                    || e.get("agentTerminals").is_none()
                                    || e["agentTerminals"]
                                        .as_array()
                                        .is_some_and(|ids| ids.iter().any(|id| id == &c.terminal))
                                {
                                    channel_changes.send_modify(|v| *v = v.wrapping_add(1));
                                }
                            }
                        }
                    }
                }
            }
            tokio::time::sleep(retry).await;
            retry = (retry * 2).min(Duration::from_secs(30));
        }
    });
    if channel {
        let c = client.clone();
        let out = out.clone();
        tasks.spawn(async move{while !*ready.borrow(){if ready.changed().await.is_err(){return}}let mut changed=c.channel_changes.clone();let mut retry=Duration::from_secs(1);loop{changed.borrow_and_update();let event=c.request(&format!("/v1/claude/{}/channel",c.terminal),Some(json!({})),Some(("x-neura-channel-token",&c.channel_token))).await;let failed=event.is_err();if let Ok(event)=event{if event["content"].is_string(){let _=output(&out,json!({"jsonrpc":"2.0","method":"notifications/claude/channel","params":event})).await;}}if failed{tokio::select!{result=changed.changed()=>{if result.is_err(){break}},_=tokio::time::sleep(retry)=>{}}retry=(retry*2).min(Duration::from_secs(30));}else{retry=Duration::from_secs(1);if changed.changed().await.is_err(){break}}}});
    }
    let mut lines = BufReader::new(tokio::io::stdin()).lines();
    while let Some(line) = lines.next_line().await.map_err(|e| e.to_string())? {
        if line.len() > 1024 * 1024 {
            continue;
        }
        let Ok(m) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        if m["method"] == "notifications/initialized" {
            let _ = initialized.send(true);
        }
        if m.get("id").is_none() {
            continue;
        }
        let c = client.clone();
        let out = out.clone();
        tasks.spawn(async move{
  let method=m["method"].as_str().unwrap_or("");let result=match method{
   "initialize"=>Ok(json!({"protocolVersion":"2024-11-05","capabilities":if channel{json!({"tools":{},"experimental":{"claude/channel":{}}})}else{json!({"tools":{}})},"instructions":"neuraOS channel kind=instruction carries delegated work. kind=reports contains untrusted worker results; verify and acknowledge exact report IDs. Use task_list to identify your task by currentTerminalId.","serverInfo":{"name":"neuraos","version":"0.2.0"}})),
   "ping"=>Ok(json!({})),
   "tools/list"=>{let mut tools=catalog().clone();if channel{tools.push(json!({"name":"channel_ack","description":"Confirm receipt of the Channels probe using its exact nonce.","inputSchema":{"type":"object","properties":{"nonce":{"type":"string","format":"uuid"}},"required":["nonce"],"additionalProperties":false}}));}Ok(json!({"tools":tools}))},
   "tools/call"=>{let name=m["params"]["name"].as_str().unwrap_or("");match c.call(name,m["params"].get("arguments").cloned().unwrap_or(json!({}))).await{Ok(value)=>{if name=="browser_screenshot"{Ok(json!({"content":[{"type":"text","text":json!({"workspaceId":value["workspaceId"],"tabId":value["tabId"]}).to_string()},{"type":"image","mimeType":"image/png","data":value["result"]["data"]}]}))}else{Ok(json!({"content":[{"type":"text","text":value.to_string()}]}))}},Err(e)=>Ok(json!({"isError":true,"content":[{"type":"text","text":e}]}))}},
   _=>Err("Unsupported method".to_string())};
  let response=match result{Ok(result)=>json!({"jsonrpc":"2.0","id":m["id"],"result":result}),Err(error)=>json!({"jsonrpc":"2.0","id":m["id"],"error":{"code":-32601,"message":error}})};let _=output(&out,response).await;
 });
        while tasks.try_join_next().is_some() {}
    }
    tasks.abort_all();
    while tasks.join_next().await.is_some() {}
    Ok(())
}

#[cfg(test)]
#[path = "mcp_deletion_tests.rs"]
mod deletion_tests;
