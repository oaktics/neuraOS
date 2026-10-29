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
