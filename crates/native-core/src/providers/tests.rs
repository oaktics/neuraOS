use super::agents::Agents;
use super::*;
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
};
#[derive(Default)]
struct MemoryStore(Mutex<HashMap<String, HashMap<String, Value>>>);
impl ProviderStore for MemoryStore {
    fn call<'a>(&'a self, op: &'a str, args: Value) -> FutureResult<'a, Value> {
        Box::pin(async move {
            let mut db = self.0.lock().unwrap();
            let table = args["table"].as_str().unwrap_or("").to_string();
            match op {
                "list" => Ok(json!(db
                    .entry(table)
                    .or_default()
                    .values()
                    .cloned()
                    .collect::<Vec<_>>())),
                "get" => Ok(db
                    .entry(table)
                    .or_default()
                    .get(args["id"].as_str().unwrap())
                    .cloned()
                    .unwrap_or(Value::Null)),
                "compare_put" => {
                    let rows = db.entry(table).or_default();
                    let key = args["id"].as_str().unwrap();
                    if rows.get(key).cloned().unwrap_or(Value::Null) != args["expected"] {
                        return Ok(json!(false));
                    }
                    rows.insert(key.into(), args["value"].clone());
                    if let Some(notification) = args.get("notification").filter(|n| n.is_object()) {
                        db.entry("notifications".into()).or_default().insert(
                            notification["id"].as_str().unwrap().into(),
                            notification.clone(),
                        );
                    }
                    Ok(json!(true))
                }
                "put" => {
                    db.entry(table).or_default().insert(
                        args["value"]["id"].as_str().unwrap().into(),
                        args["value"].clone(),
                    );
                    Ok(Value::Null)
                }
                _ => Err(format!("unsupported {op}")),
            }
        })
    }
}
#[derive(Default)]
struct RuntimeStub {
    calls: Mutex<Vec<(String, Value)>>,
}
impl ProviderRuntime for RuntimeStub {
    fn rpc<'a>(&'a self, _: &'a str, method: &'a str, params: Value) -> FutureResult<'a, Value> {
        Box::pin(async move {
            self.calls.lock().unwrap().push((method.into(), params));
            Ok(json!({"turn":{"id":id()}}))
        })
    }
    fn reply<'a>(&'a self, _: &'a str, _: Value, _: Value) -> FutureResult<'a, ()> {
        Box::pin(async { Ok(()) })
    }
    fn interrupt<'a>(&'a self, _: &'a str, _: bool) -> FutureResult<'a, ()> {
        Box::pin(async { Ok(()) })
    }
}
async fn fixture() -> (Arc<MemoryStore>, Arc<Agents>) {
    let store = Arc::new(MemoryStore::default());
    let agents = Arc::new(
        Agents::new(store.clone(), Arc::new(RuntimeStub::default()))
            .await
            .unwrap(),
    );
    (store, agents)
}
async fn claude(agents: &Agents, parent: Option<String>) -> (String, String) {
    let terminal = id();
    let task = id();
    agents
        .prepare_claude(
            json!({"id":"w","path":"/tmp/w","name":"work"}),
            &terminal,
            None,
            parent,
            None,
        )
        .await
        .unwrap();
    assert!(agents.claude_event(&terminal,&json!({"hook_event_name":"SessionStart","session_id":task,"transcript_path":"/tmp/fixture.jsonl"})).await.unwrap());
    (terminal, task)
}
async fn event(agents: &Agents, terminal: &str, task: &str, name: &str, extra: Value) -> bool {
    let mut value =
        json!({"hook_event_name":name,"session_id":task,"transcript_path":"/tmp/fixture.jsonl"});
    value
        .as_object_mut()
        .unwrap()
        .extend(extra.as_object().unwrap().clone());
    agents.claude_event(terminal, &value).await.unwrap()
}
async fn confirm(agents: &Agents, terminal: &str, task: &str) {
    let probe = agents.channel(terminal).await.unwrap();
    let content = probe["content"].as_str().unwrap();
    let nonce = content
        .split("nonce ")
        .nth(1)
        .unwrap()
        .split(',')
        .next()
        .unwrap();
    agents.acknowledge_channel(terminal, nonce).await.unwrap();
    event(agents, terminal, task, "Stop", json!({})).await;
}
#[tokio::test]
async fn arbitrary_child_count_and_exact_ack_keep_instructions_separate() {
    for count in [10, 20, 32, 40] {
        let (_, agents) = fixture().await;
        let (parent_terminal, parent) = claude(&agents, None).await;
        confirm(&agents, &parent_terminal, &parent).await;
        let mut children = vec![];
        for _ in 0..count {
            children.push(claude(&agents, Some(parent.clone())).await);
        }
        assert_eq!(agents.get(&parent).await.unwrap().watching.len(), count);
        for (terminal, task) in &children {
            event(&agents, terminal, task, "UserPromptSubmit", json!({})).await;
            event(
                &agents,
                terminal,
                task,
                "Stop",
                json!({"last_assistant_message":"verified"}),
            )
            .await;
        }
        let p = agents.get(&parent).await.unwrap();
        assert_eq!(p.reports.len(), count.min(32));
        assert_eq!(p.watching.len(), count.saturating_sub(32));
        let ids = p.reports.iter().map(|r| r.id.clone()).collect::<Vec<_>>();
        let instruction = agents
            .send(&parent, "keep instruction", "queue", None)
            .await
            .unwrap();
        let mut ack = ids.clone();
        ack.push(instruction["messageId"].as_str().unwrap().into());
        agents.ack(&parent, &ack).await.unwrap();
        let p = agents.get(&parent).await.unwrap();
        assert_eq!(p.pending.len(), 1);
        assert_eq!(p.reports.len(), count.saturating_sub(32));
        assert!(p.watching.is_empty());
        agents.ack(&parent, &ids).await.unwrap();
        assert_eq!(
            agents.get(&parent).await.unwrap().reports.len(),
            count.saturating_sub(32)
        );
    }
}
#[tokio::test]
async fn channel_delivery_is_serial_and_never_replays_after_uncertain_transport() {
    let (_, agents) = fixture().await;
    let (terminal, task) = claude(&agents, None).await;
    confirm(&agents, &terminal, &task).await;
    agents.send(&task, "once", "queue", None).await.unwrap();
    let mut jobs = vec![];
    for _ in 0..32 {
        let agents = agents.clone();
        let terminal = terminal.clone();
        jobs.push(tokio::spawn(async move {
            agents.channel(&terminal).await.unwrap()
        }));
    }
    let mut delivered = 0;
    for job in jobs {
        if job.await.unwrap()["content"] == "once" {
            delivered += 1;
        }
    }
    assert_eq!(delivered, 1);
    assert!(agents.get(&task).await.unwrap().pending.is_empty());
    assert!(agents.channel(&terminal).await.unwrap()["content"].is_null());
}
#[tokio::test]
async fn old_session_turn_and_stop_cannot_finish_new_work() {
    let (_, agents) = fixture().await;
    let (terminal, task) = claude(&agents, None).await;
    confirm(&agents, &terminal, &task).await;
    event(
        &agents,
        &terminal,
        &task,
        "UserPromptSubmit",
        json!({"observed_at":"2000","turn_id":"new"}),
    )
    .await;
    let turn = agents.get(&task).await.unwrap().turn_id;
    assert!(
        !event(
            &agents,
            &terminal,
            &task,
            "Stop",
            json!({"observed_at":"1000","last_assistant_message":"old"})
        )
        .await
    );
    assert!(
        !event(
            &agents,
            &terminal,
            &task,
            "Stop",
            json!({"turn_id":"old","observed_at":"3000"})
        )
        .await
    );
    assert!(!event(&agents, &terminal, &id(), "Stop", json!({})).await);
    assert_eq!(agents.get(&task).await.unwrap().turn_id, turn);
    assert!(
        event(
            &agents,
            &terminal,
            &task,
            "Stop",
            json!({"observed_at":"3000","turn_id":"new"})
        )
        .await
    );
    assert!(
        !event(
            &agents,
            &terminal,
            &task,
            "Stop",
            json!({"observed_at":"3000","turn_id":"new"})
        )
        .await
    );
}
#[tokio::test]
async fn concurrent_reports_are_durable_and_self_report_is_rejected() {
    let (store, agents) = fixture().await;
    let (terminal, task) = claude(&agents, None).await;
    store
        .call(
            "put",
            json!({"table":"terminals","value":{"id":terminal,"agentId":task}}),
        )
        .await
        .unwrap();
    assert!(agents
        .report(&task, "self", Some(&terminal))
        .await
        .unwrap_err()
        .starts_with("report_to_self"));
    let mut jobs = vec![];
    for n in 0..32 {
        let agents = agents.clone();
        let task = task.clone();
        jobs.push(tokio::spawn(async move {
            agents.report(&task, &format!("report {n}"), None).await
        }));
    }
    for job in jobs {
        job.await.unwrap().unwrap();
    }
    assert_eq!(agents.get(&task).await.unwrap().reports.len(), 32);
    assert_eq!(
        agents.report(&task, "full", None).await.unwrap_err(),
        "agent_reports_full"
    );
    let restarted = Agents::new(store, Arc::new(RuntimeStub::default()))
        .await
        .unwrap();
    assert_eq!(restarted.get(&task).await.unwrap().reports.len(), 32);
    assert_eq!(restarted.get(&task).await.unwrap().status, "interrupted");
}
#[tokio::test]
async fn watches_reject_cycles_without_parallel_cap() {
    let (_, agents) = fixture().await;
    let (_, a) = claude(&agents, None).await;
    let (_, b) = claude(&agents, None).await;
    agents.watch(&a, &[b.clone()]).await.unwrap();
    assert_eq!(
        agents.watch(&b, &[a.clone()]).await.unwrap_err(),
        "agent_watch_cycle"
    );
    assert_eq!(
        agents.watch(&a, &[a.clone()]).await.unwrap_err(),
        "agent_watch_cycle"
    );
}
#[test]
fn incremental_transcripts_skip_idle_reads_and_keep_flush_inode_fences() {
    let root = std::env::temp_dir().join(format!("neura-rust-transcript-{}", id()));
    std::fs::create_dir(&root).unwrap();
    let path = root.join("session.jsonl");
    let row = |kind: &str, extra: Value| {
        let mut v = json!({"type":kind,"sessionId":"s","timestamp":"2026-10-29T00:00:00Z"});
        v.as_object_mut()
            .unwrap()
            .extend(extra.as_object().unwrap().clone());
        format!("{v}\n")
    };
    let assistant = row(
        "assistant",
        json!({"message":{"content":[{"type":"text","text":"result"}]}}),
    );
    std::fs::write(&path, &assistant).unwrap();
    let mut reader = claude::CompletionReader::default();
    assert!(reader.read(&path, "s", 0).unwrap().is_none());
    let bytes = reader.bytes_read;
    for _ in 0..32 {
        assert!(reader.read(&path, "s", 0).unwrap().is_none());
    }
    assert_eq!(reader.bytes_read, bytes);
    use std::io::Write;
    std::fs::OpenOptions::new()
        .append(true)
        .open(&path)
        .unwrap()
        .write_all(row("system", json!({"subtype":"turn_duration"})).as_bytes())
        .unwrap();
    assert_eq!(
        reader.read(&path, "s", 0).unwrap().unwrap()["last_assistant_message"],
        "result"
    );
    assert_eq!(reader.bytes_read, std::fs::metadata(&path).unwrap().len());
    std::fs::OpenOptions::new()
        .append(true)
        .open(&path)
        .unwrap()
        .write_all(b"{\"type\":")
        .unwrap();
    assert!(reader.read(&path, "s", 0).unwrap().is_none());
    let replacement = root.join("new");
    std::fs::write(&replacement, row("user", json!({}))).unwrap();
    std::fs::rename(&replacement, &path).unwrap();
    assert!(reader.read(&path, "s", 0).unwrap().is_none());
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn giant_append_uses_bounded_tail_and_keeps_exact_session_and_partial_flush_guards() {
    let root = std::env::temp_dir().join(format!("neura-native-large-{}", id()));
    std::fs::create_dir(&root).unwrap();
    let path = root.join("session.jsonl");
    std::fs::write(
        &path,
        "{\"type\":\"user\",\"sessionId\":\"s\",\"timestamp\":\"2026-10-29T00:00:00Z\"}\n",
    )
    .unwrap();
    let mut reader = claude::CompletionReader::default();
    reader.read(&path, "s", 0).unwrap();
    let before = reader.bytes_read;
    use std::io::Write;
    let mut file = std::fs::OpenOptions::new()
        .append(true)
        .open(&path)
        .unwrap();
    write!(file,"{}\n{}\n{}\n",json!({"type":"tool","payload":"x".repeat(16*1024*1024)}),json!({"type":"assistant","sessionId":"s","timestamp":"2026-10-29T00:00:00Z","message":{"content":[{"type":"text","text":"bounded result"}]}}),json!({"type":"system","sessionId":"s","timestamp":"2026-10-29T00:00:00Z","subtype":"turn_duration"})).unwrap();
    file.flush().unwrap();
    assert_eq!(
        reader.read(&path, "s", 0).unwrap().unwrap()["last_assistant_message"],
        "bounded result"
    );
    assert!(reader.bytes_read - before <= 512 * 1024);
    assert!(reader.read(&path, "other", 0).unwrap().is_none());
    file.write_all(b"{\"type\":\"user\"").unwrap();
    file.flush().unwrap();
    assert!(reader.read(&path, "s", 0).unwrap().is_none());
    std::fs::remove_dir_all(root).unwrap();
}

#[tokio::test]
async fn native_file_notification_recovers_completion_after_append_without_polling() {
    let (_, agents) = fixture().await;
    let root = std::env::temp_dir().join(format!("neura-native-watch-{}", id()));
    std::fs::create_dir(&root).unwrap();
    let path = root.join("session.jsonl");
    std::fs::write(&path, "").unwrap();
    let terminal = id();
    let task = id();
    agents
        .prepare_claude(
            json!({"id":"w","name":"w","path":root}),
            &terminal,
            None,
            None,
            None,
        )
        .await
        .unwrap();
    agents
        .claude_event(
            &terminal,
            &json!({"hook_event_name":"SessionStart","session_id":task,"transcript_path":path}),
        )
        .await
        .unwrap();
    agents.claude_event(&terminal,&json!({"hook_event_name":"UserPromptSubmit","session_id":task,"transcript_path":path,"observed_at":"1"})).await.unwrap();
    let monitor = claude::CompletionMonitor::start(agents.clone()).unwrap();
    monitor.observe(&terminal, path.clone()).unwrap();
    tokio::time::sleep(std::time::Duration::from_millis(80)).await;
    std::fs::write(&path,format!("{}\n{}\n",json!({"type":"assistant","sessionId":task,"timestamp":"2026-10-29T00:00:00Z","message":{"content":[{"type":"text","text":"native notification"}]}}),json!({"type":"system","subtype":"turn_duration","sessionId":task,"timestamp":"2026-10-29T00:00:00Z"}))).unwrap();
    tokio::time::timeout(std::time::Duration::from_secs(4), async {
        loop {
            if agents.get(&task).await.unwrap().status == "idle" {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
    assert_eq!(
        agents.get(&task).await.unwrap().summary.as_deref(),
        Some("native notification")
    );
    monitor.close();
    monitor.remove(&terminal);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn tail_skips_partial_utf8_before_decoding_valid_japanese_stop_and_title() {
    let root = std::env::temp_dir().join(format!("neura-native-utf8-{}", id()));
    std::fs::create_dir(&root).unwrap();
    let path = root.join("session.jsonl");
    let mut checked = false;
    for padding in 0..3 {
        let session = "s";
        let content = format!(
            "{}\n{}\n{}\n{}{}\n",
            json!({"type":"tool","payload":"あ".repeat(300000)}),
            json!({"type":"ai-title","sessionId":session,"aiTitle":"日本語の完了"}),
            json!({"type":"assistant","sessionId":session,"timestamp":"2026-10-29T00:00:00Z","message":{"content":[{"type":"text","text":"検証済み"}]}}),
            json!({"type":"system","subtype":"turn_duration","sessionId":session,"timestamp":"2026-10-29T00:00:00Z"}),
            " ".repeat(padding)
        );
        let bytes = content.as_bytes();
        let start = bytes.len() - 512 * 1024;
        if bytes[start] & 0xc0 != 0x80 {
            continue;
        }
        std::fs::write(&path, bytes).unwrap();
        let mut reader = claude::CompletionReader::default();
        assert_eq!(
            reader.read(&path, session, 0).unwrap().unwrap()["last_assistant_message"],
            "検証済み"
        );
        assert_eq!(reader.title.as_ref().unwrap().0, "日本語の完了");
        assert_eq!(reader.bytes_read, 512 * 1024);
        checked = true;
        break;
    }
    assert!(checked, "fixture must start inside a multibyte code point");
    std::fs::remove_dir_all(root).unwrap();
}

#[tokio::test]
async fn startup_recovery_persists_interruption_and_keeps_pending_reports() {
    let dir = std::env::temp_dir().join(format!("neura-agent-recovery-{}", id()));
    std::fs::create_dir(&dir).unwrap();
    let (events, _) = tokio::sync::broadcast::channel(16);
    let store = crate::store::StoreHandle::open(&dir.join("test.sqlite"), events)
        .await
        .unwrap();
    let pending = json!([{"id":"instruction","text":"keep queued work"}]);
    let reports = json!([{"id":"report","kind":"worker","text":"keep unacknowledged report","createdAt":"2026-10-29T00:00:00Z"}]);
    let row = json!({"id":"recover","terminalId":"terminal","workspaceId":"workspace","name":"recovery","provider":"codex","status":"working","updatedAt":"2026-10-29T00:00:00Z","turnId":"in-flight","requests":[{"id":"approval"}],"pending":pending,"reports":reports,"watching":[]});
    store.put("agents", row, None).await.unwrap();
    let agents = Agents::new(Arc::new(store.clone()), Arc::new(RuntimeStub::default()))
        .await
        .unwrap();
    assert_eq!(agents.get("recover").await.unwrap().status, "interrupted");
    let persisted = store.get("agents", "recover").await.unwrap().unwrap();
    assert_eq!(persisted["status"], "interrupted");
    assert!(persisted.get("turnId").is_none());
    assert_eq!(persisted["requests"], json!([]));
    assert_eq!(persisted["pending"][0]["id"], pending[0]["id"]);
    assert_eq!(persisted["pending"][0]["text"], pending[0]["text"]);
    assert_eq!(persisted["pending"][0]["state"], "queued");
    assert_eq!(persisted["reports"], reports);
    // A second startup must see the durable recovery, without losing inboxes.
    drop(agents);
    let restarted = Agents::new(Arc::new(store.clone()), Arc::new(RuntimeStub::default()))
        .await
        .unwrap();
    assert_eq!(
        serde_json::to_value(restarted.get("recover").await.unwrap()).unwrap(),
        persisted
    );
    assert_eq!(
        store.get("agents", "recover").await.unwrap().unwrap(),
        persisted
    );
}

#[tokio::test]
async fn snapshot_preserves_legacy_claude_session_ids_without_agent_id() {
    let dir = std::env::temp_dir().join(format!("neura-legacy-session-map-{}", id()));
    std::fs::create_dir(&dir).unwrap();
    let (events, _) = tokio::sync::broadcast::channel(16);
    let store = crate::store::StoreHandle::open(&dir.join("test.sqlite"), events)
        .await
        .unwrap();
    for terminal in [
        json!({"id":"legacy","workspaceId":"w","provider":"claude","sessionId":"claude-session"}),
        json!({"id":"current","workspaceId":"w","provider":"claude","sessionId":"current-session","agentId":"stale-agent"}),
        json!({"id":"pending","workspaceId":"w","provider":"claude","agentId":"not-a-confirmed-session"}),
        json!({"id":"codex","workspaceId":"w","provider":"codex","sessionId":"codex-thread","agentId":"codex-thread"}),
    ] {
        store.put("terminals", terminal, None).await.unwrap();
    }
    let pty = crate::pty::PtyRuntime::new(store.clone()).unwrap();
    let providers = integration::ProviderService::new(
        store,
        pty.clone(),
        "http://127.0.0.1:1".into(),
        dir.join("token").display().to_string(),
    )
    .await
    .unwrap();
    assert_eq!(
        providers.snapshot().await.unwrap()["currentSessionIds"],
        json!({"legacy":"claude-session","current":"current-session"})
    );
    providers.shutdown().await.unwrap();
    pty.shutdown().await.unwrap();
}

async fn codex_fixture() -> (Arc<MemoryStore>, Arc<Agents>, Value) {
    let (store, agents) = fixture().await;
    let workspace = json!({"id":"w","path":"/tmp/w","name":"work"});
    store
        .call(
            "put",
            json!({"table":"terminals","value":{"id":"t","workspaceId":"w","provider":"codex"}}),
        )
        .await
        .unwrap();
    (store, agents, workspace)
}
fn codex_thread(task: &str) -> Value {
    json!({"id":task,"cwd":"/tmp/w","name":format!("name {task}"),"status":{"type":"idle"}})
}
async fn terminal_binding(store: &MemoryStore, terminal: &str) -> Value {
    let t = store
        .call("get", json!({"table":"terminals","id":terminal}))
        .await
        .unwrap();
    json!([t["agentId"], t["sessionId"], t["sessionName"]])
}
async fn notifications(store: &MemoryStore) -> usize {
    store
        .call("list", json!({"table":"notifications"}))
        .await
        .unwrap()
        .as_array()
        .unwrap()
        .len()
}
#[tokio::test]
async fn codex_repeated_discovery_preserves_selection_and_explicit_selection_still_changes_it() {
    let (store, agents, workspace) = codex_fixture().await;
    agents
        .register_codex("t", &workspace, &codex_thread("selected"), None)
        .await
        .unwrap();
    let selected = terminal_binding(&store, "t").await;
    for tasks in [
        ["selected", "other"],
        ["other", "selected"],
        ["selected", "other"],
    ] {
        for task in tasks {
            assert!(agents
                .discover_codex("t", &workspace, &codex_thread(task))
                .await
                .unwrap());
            assert_eq!(terminal_binding(&store, "t").await, selected);
        }
    }
    assert_eq!(agents.get("other").await.unwrap().terminal_id, "t");
    agents
        .codex_event(
            "t",
            &workspace,
            &json!({"method":"thread/started","params":{"thread":codex_thread("other")}}),
        )
        .await
        .unwrap();
    assert_eq!(
        terminal_binding(&store, "t").await,
        json!(["other", "other", "name other"])
    );
    agents
        .discover_codex("t", &workspace, &codex_thread("selected"))
        .await
        .unwrap();
    assert_eq!(
        terminal_binding(&store, "t").await,
        json!(["other", "other", "name other"])
    );
    assert_eq!(notifications(&store).await, 0);
}
#[tokio::test]
async fn codex_completion_notifies_only_newly_accepted_turns() {
    let (store, agents, workspace) = codex_fixture().await;
    agents
        .register_codex("t", &workspace, &codex_thread("selected"), None)
        .await
        .unwrap();
    let completion = |task: &str, turn: &str| json!({"method":"turn/completed","params":{"threadId":task,"turn":{"id":turn,"status":"completed"}}});
    agents
        .codex_event("t", &workspace, &completion("unknown", "one"))
        .await
        .unwrap();
    assert_eq!(notifications(&store).await, 0);
    agents
        .codex_event("t", &workspace, &completion("selected", "one"))
        .await
        .unwrap();
    assert_eq!(notifications(&store).await, 1);
    for _ in 0..3 {
        agents
            .discover_codex("t", &workspace, &codex_thread("selected"))
            .await
            .unwrap();
        agents
            .codex_event("t", &workspace, &completion("selected", "one"))
            .await
            .unwrap();
    }
    assert_eq!(notifications(&store).await, 1);
    agents
        .codex_event(
            "t",
            &workspace,
            &json!({"method":"turn/started","params":{"threadId":"selected","turn":{"id":"two"}}}),
        )
        .await
        .unwrap();
    agents
        .codex_event("t", &workspace, &completion("selected", "stale"))
        .await
        .unwrap();
    assert_eq!(
        agents.get("selected").await.unwrap().turn_id.as_deref(),
        Some("two")
    );
    assert_eq!(notifications(&store).await, 1);
    agents
        .codex_event("t", &workspace, &completion("selected", "two"))
        .await
        .unwrap();
    agents
        .codex_event("t", &workspace, &completion("selected", "two"))
        .await
        .unwrap();
    assert_eq!(notifications(&store).await, 2);
}
#[tokio::test]
async fn codex_discovery_preserves_delegation_and_resume_ownership() {
    let (store, agents, workspace) = codex_fixture().await;
    agents
        .register_codex("parent-terminal", &workspace, &codex_thread("parent"), None)
        .await
        .unwrap();
    agents
        .register_codex(
            "t",
            &workspace,
            &codex_thread("child"),
            Some("parent".into()),
        )
        .await
        .unwrap();
    agents
        .discover_codex("t", &workspace, &codex_thread("other"))
        .await
        .unwrap();
    agents
        .discover_codex("t", &workspace, &codex_thread("child"))
        .await
        .unwrap();
    assert_eq!(
        agents.get("child").await.unwrap().parent_task_id.as_deref(),
        Some("parent")
    );
    assert_eq!(agents.get("parent").await.unwrap().watching.len(), 1);
    agents
        .report("parent", "child report", Some("t"))
        .await
        .unwrap();
    let parent = agents.get("parent").await.unwrap();
    assert_eq!(parent.reports[0].source_task_id.as_deref(), Some("child"));
    assert_eq!(
        agents
            .register_codex("resumed", &workspace, &codex_thread("child"), None)
            .await
            .unwrap_err(),
        "agent_already_running"
    );
    agents.close("t").await.unwrap();
    store.call("put", json!({"table":"terminals","value":{"id":"resumed","workspaceId":"w","provider":"codex"}})).await.unwrap();
    agents
        .register_codex("resumed", &workspace, &codex_thread("child"), None)
        .await
        .unwrap();
    assert_eq!(
        terminal_binding(&store, "resumed").await,
        json!(["child", "child", "name child"])
    );
    assert_eq!(
        agents.get("child").await.unwrap().parent_task_id.as_deref(),
        Some("parent")
    );
}

#[tokio::test]
async fn report_unicode_lengths_match_wire_contract_and_preserve_text() {
    let (_, agents) = fixture().await;
    let (_, task) = claude(&agents, None).await;
    for text in [
        "日".repeat(6000),
        "日".repeat(16384),
        "🦀".repeat(8192),
        format!("{}日", "🦀".repeat(8191)),
        format!("{}日本", "🦀".repeat(8191)),
    ] {
        let command = crate::contracts::command(json!({
            "type":"agent.report", "agentId":task, "text":text
        }))
        .unwrap();
        let result = agents.command(&command).await.unwrap();
        let agent = agents.get(&task).await.unwrap();
        let report = agent
            .reports
            .iter()
            .find(|r| r.id == result["reportId"])
            .unwrap();
        assert_eq!(report.text, text);
    }
    assert_eq!(agents.get(&task).await.unwrap().reports.len(), 5);
}

#[tokio::test]
async fn report_rejects_over_limit_utf16_without_mutation() {
    let (_, agents) = fixture().await;
    let (_, task) = claude(&agents, None).await;
    for text in [
        "日".repeat(16385),
        "🦀".repeat(8193),
        format!("{}日", "🦀".repeat(8192)),
        String::new(),
        " \n\t".into(),
    ] {
        assert!(crate::contracts::command(json!({
            "type":"agent.report", "agentId":task, "text":text
        }))
        .is_err());
        assert_eq!(
            agents.report(&task, &text, None).await.unwrap_err(),
            "invalid_report"
        );
        assert!(agents.get(&task).await.unwrap().reports.is_empty());
    }
}

#[path = "instruction_tests.rs"]
mod instruction_tests;
