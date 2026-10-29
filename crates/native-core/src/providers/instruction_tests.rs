use super::*;
async fn mutation(a: &Agents, task: &str, terminal: &str, key: &str, action: &str) -> Value {
    let current = a.get(task).await.unwrap();
    let m = current
        .pending
        .iter()
        .chain(current.instructions.iter())
        .find(|m| m.id == key)
        .unwrap();
    json!({"type":"agent.instruction","agentId":task,"sourceTerminalId":terminal,"instructionId":key,"expectedRevision":current.revision,"expectedTurnId":current.turn_id,"expectedState":m.state,"action":action})
}
#[tokio::test]
async fn consume_cancel_supersede_preserve_other_work_and_survive_restart() {
    let (store, a) = fixture().await;
    let (pt, parent) = claude(&a, None).await;
    let (ct, child) = claude(&a, Some(parent.clone())).await;
    confirm(&a, &pt, &parent).await;
    confirm(&a, &ct, &child).await;
    event(&a, &ct, &child, "UserPromptSubmit", json!({})).await;
    let mut keys = vec![];
    for text in ["already handled", "obsolete", "replace me", "keep me"] {
        keys.push(
            a.send(&child, text, "queue", None).await.unwrap()["messageId"]
                .as_str()
                .unwrap()
                .to_string(),
        );
    }
    let before = a.get(&child).await.unwrap();
    let denied = mutation(&a, &child, &pt, &keys[0], "consume").await;
    assert_eq!(
        a.instruction(&denied).await.unwrap_err(),
        "instruction_forbidden"
    );
    let consume = mutation(&a, &child, &ct, &keys[0], "consume").await;
    let mut wrong = consume.clone();
    wrong["expectedTurnId"] = json!(id());
    assert_eq!(
        a.instruction(&wrong).await.unwrap_err(),
        "agent_turn_changed"
    );
    let mut wrong = consume.clone();
    wrong["expectedState"] = json!("delivered");
    assert_eq!(
        a.instruction(&wrong).await.unwrap_err(),
        "instruction_state_changed"
    );
    a.instruction(&consume).await.unwrap();
    assert_eq!(
        a.instruction(&consume).await.unwrap_err(),
        "instruction_revision_changed"
    );
    a.instruction(&mutation(&a, &child, &pt, &keys[1], "cancel").await)
        .await
        .unwrap();
    let mut replace = mutation(&a, &child, &pt, &keys[2], "supersede").await;
    replace["text"] = json!("new design");
    let result = a.instruction(&replace).await.unwrap();
    let after = a.get(&child).await.unwrap();
    assert_eq!(
        after
            .pending
            .iter()
            .map(|m| m.text.as_str())
            .collect::<Vec<_>>(),
        ["new design", "keep me"]
    );
    assert_eq!(
        after
            .instructions
            .iter()
            .map(|m| m.state.as_str())
            .collect::<Vec<_>>(),
        ["consumed", "cancelled", "superseded"]
    );
    assert_eq!(
        after.instructions[2].history.last().unwrap()["replacementId"],
        result["replacementId"]
    );
    event(&a, &ct, &child, "Stop", json!({})).await;
    let delivered = a.channel(&ct).await.unwrap();
    assert_eq!(delivered["content"], "new design");
    assert_eq!(delivered["meta"]["instruction_id"], result["replacementId"]);
    let new_key = result["replacementId"].as_str().unwrap();
    assert_eq!(
        a.instruction(&mutation(&a, &child, &pt, new_key, "cancel").await)
            .await
            .unwrap_err(),
        "instruction_not_retractable"
    );
    a.instruction(&mutation(&a, &child, &ct, new_key, "consume").await)
        .await
        .unwrap();
    let restored = Agents::new(store, Arc::new(RuntimeStub::default()))
        .await
        .unwrap();
    let recovered = restored.get(&child).await.unwrap();
    assert_eq!(recovered.pending.len(), 1);
    assert_eq!(recovered.pending[0].text, "keep me");
    assert_eq!(recovered.instructions.len(), 4);
    assert!(recovered.revision > before.revision);
}
#[tokio::test]
async fn read_does_not_consume_or_ack_and_list_delta_pages_are_consistent() {
    let (store, a, workspace) = codex_fixture().await;
    let task = id();
    a.register_codex("t", &workspace, &codex_thread(&task), None)
        .await
        .unwrap();
    a.send(&task, "delivered text", "queue", None)
        .await
        .unwrap();
    a.send(&task, "queued text", "queue", None).await.unwrap();
    let before = serde_json::to_value(a.get(&task).await.unwrap()).unwrap();
    a.read(&task, None).await.unwrap();
    let full = a.query(json!({"taskIds":[task]})).await.unwrap();
    let lite = a
        .query(json!({"taskIds":[task],"summaryOnly":true}))
        .await
        .unwrap();
    assert_eq!(
        before,
        serde_json::to_value(a.get(&task).await.unwrap()).unwrap()
    );
    assert!(lite.to_string().len() < full.to_string().len());
    assert!(lite["agents"][0].get("pending").is_none());
    let revision = lite["revision"].clone();
    let epoch = lite["epoch"].clone();
    let filter = lite["filter"].clone();
    let idle = a.query(json!({"status":"idle"})).await.unwrap();
    let unchanged = a
        .query(json!({"taskIds":[task],"sinceRevision":revision,"sinceEpoch":epoch,"sinceFilter":filter,"summaryOnly":true}))
        .await
        .unwrap();
    assert_eq!(unchanged["unchanged"], true);
    a.send(&task, "additional", "queue", None).await.unwrap();
    let delta = a.query(json!({"taskIds":[task],"sinceRevision":revision,"sinceEpoch":epoch,"sinceFilter":filter,"summaryOnly":true})).await.unwrap();
    assert_eq!(delta["agents"].as_array().unwrap().len(), 1);
    assert_eq!(delta["agents"][0]["pendingCount"], 2);
    let hidden = a
        .query(json!({"status":"idle","sinceRevision":idle["revision"],"sinceEpoch":idle["epoch"],"sinceFilter":idle["filter"]}))
        .await
        .unwrap();
    assert_eq!(hidden["removedTaskIds"], json!([task]));
    let restart = Agents::new(store, Arc::new(RuntimeStub::default()))
        .await
        .unwrap();
    assert_eq!(
        restart
            .query(json!({"taskIds":[task],"summaryOnly":true,"sinceRevision":revision,"sinceEpoch":epoch,"sinceFilter":filter}))
            .await
            .unwrap()["fullRefreshRequired"],
        true
    );
    a.forget_workspace(workspace["id"].as_str().unwrap()).await;
    assert_eq!(
        a.query(json!({"taskIds":[task],"summaryOnly":true,"sinceRevision":revision,"sinceEpoch":epoch,"sinceFilter":filter}))
            .await
            .unwrap()["removedTaskIds"],
        json!([task])
    );
}
#[tokio::test]
async fn large_lightweight_fixture_paging_and_cursor_expiry() {
    let (store, a) = fixture().await;
    for _ in 0..40 {
        let (terminal, task) = claude(&a, None).await;
        a.send(&task, &"pending".repeat(5000), "queue", None)
            .await
            .unwrap();
        a.report(&task, &"report".repeat(2000), None).await.unwrap();
        a.close(&terminal).await.unwrap();
    }
    let full = a.query(json!({"limit":500})).await.unwrap();
    let light = a.query(json!({"summaryOnly":true})).await.unwrap();
    eprintln!(
        "list fixture bytes: full={} summary={}",
        full.to_string().len(),
        light.to_string().len()
    );
    assert!(light.to_string().len() < full.to_string().len());
    let reports_before = store.call("list", json!({"table":"agents"})).await.unwrap();
    let first = a
        .query(json!({"summaryOnly":true,"limit":7}))
        .await
        .unwrap();
    let changed_filter = a
        .query(json!({"summaryOnly":false,"limit":7,"cursor":first["nextCursor"]}))
        .await
        .unwrap();
    assert_eq!(changed_filter["fullRefreshRequired"], true);
    assert_eq!(changed_filter["reason"], "filter_changed");
    let mut ids = Vec::new();
    let mut page = first.clone();
    loop {
        ids.extend(
            page["agents"]
                .as_array()
                .unwrap()
                .iter()
                .map(|a| a["id"].as_str().unwrap().to_string()),
        );
        if page["nextCursor"].is_null() {
            break;
        }
        page = a
            .query(json!({"summaryOnly":true,"limit":7,"cursor":page["nextCursor"]}))
            .await
            .unwrap();
    }
    assert_eq!(ids.len(), 40);
    ids.sort();
    ids.dedup();
    assert_eq!(ids.len(), 40);
    assert_eq!(
        reports_before,
        store.call("list", json!({"table":"agents"})).await.unwrap()
    );
    claude(&a, None).await;
    assert_eq!(
        a.query(json!({"summaryOnly":true,"limit":7,"cursor":first["nextCursor"]}))
            .await
            .unwrap()["fullRefreshRequired"],
        true
    );
}

#[derive(Default)]
struct BlockedDelivery {
    started: tokio::sync::Notify,
    release: tokio::sync::Notify,
}
impl ProviderRuntime for BlockedDelivery {
    fn rpc<'a>(&'a self, _: &'a str, _: &'a str, _: Value) -> FutureResult<'a, Value> {
        Box::pin(async move {
            self.started.notify_one();
            self.release.notified().await;
            Err("transport_lost".into())
        })
    }
    fn reply<'a>(&'a self, _: &'a str, _: Value, _: Value) -> FutureResult<'a, ()> {
        Box::pin(async { Ok(()) })
    }
    fn interrupt<'a>(&'a self, _: &'a str, _: bool) -> FutureResult<'a, ()> {
        Box::pin(async { Ok(()) })
    }
}
#[tokio::test]
async fn delivery_race_and_restart_never_claim_cancellation_or_redeliver_unknown() {
    let store = Arc::new(MemoryStore::default());
    store
        .call(
            "put",
            json!({"table":"terminals","value":{"id":"t","workspaceId":"w","provider":"codex"}}),
        )
        .await
        .unwrap();
    let runtime = Arc::new(BlockedDelivery::default());
    let a = Arc::new(Agents::new(store.clone(), runtime.clone()).await.unwrap());
    let task = id();
    let workspace = json!({"id":"w","path":"/tmp/w","name":"work"});
    a.register_codex("t", &workspace, &codex_thread(&task), None)
        .await
        .unwrap();
    let worker = {
        let a = a.clone();
        let task = task.clone();
        tokio::spawn(async move { a.send(&task, "uncertain delivery", "queue", None).await })
    };
    runtime.started.notified().await;
    let snapshot = a.get(&task).await.unwrap();
    assert!(snapshot.pending.is_empty());
    assert_eq!(snapshot.instructions[0].state, "delivering");
    let cancel = mutation(&a, &task, "t", &snapshot.instructions[0].id, "cancel").await;
    assert_eq!(
        a.instruction(&cancel).await.unwrap_err(),
        "instruction_not_retractable"
    );
    let recovered = Agents::new(store.clone(), Arc::new(RuntimeStub::default()))
        .await
        .unwrap();
    let persisted = recovered.get(&task).await.unwrap();
    assert_eq!(persisted.instructions[0].state, "unknown");
    assert!(persisted.pending.is_empty());
    runtime.release.notify_one();
    assert_eq!(worker.await.unwrap().unwrap_err(), "transport_lost");
    assert_eq!(a.get(&task).await.unwrap().instructions[0].state, "unknown");
    let key = snapshot.instructions[0].id.clone();
    for action in ["consume", "cancel", "supersede"] {
        let command = mutation(&a, &task, "t", &key, action).await;
        assert_eq!(
            a.instruction(&command).await.unwrap_err(),
            "instruction_not_retractable"
        );
    }
}
#[tokio::test]
async fn simultaneous_cancel_and_supersede_only_one_wins_and_sibling_is_denied() {
    let (_, a) = fixture().await;
    let (t, task) = claude(&a, None).await;
    let (other, _) = claude(&a, None).await;
    let key = a.send(&task, "old", "queue", None).await.unwrap()["messageId"]
        .as_str()
        .unwrap()
        .to_string();
    assert_eq!(
        a.instruction(&mutation(&a, &task, &other, &key, "cancel").await)
            .await
            .unwrap_err(),
        "instruction_forbidden"
    );
    let cancel = mutation(&a, &task, &t, &key, "cancel").await;
    let mut replace = cancel.clone();
    replace["action"] = json!("supersede");
    replace["text"] = json!("new");
    let (one, two) = tokio::join!(a.instruction(&cancel), a.instruction(&replace));
    assert_ne!(one.is_ok(), two.is_ok());
    assert_eq!(
        one.err().or(two.err()).unwrap(),
        "instruction_revision_changed"
    );
    assert_eq!(a.get(&task).await.unwrap().instructions.len(), 1);
}

#[tokio::test]
async fn discovered_old_codex_session_cannot_grant_parent_authority() {
    let (_, a, workspace) = codex_fixture().await;
    let old = id();
    let selected = id();
    a.register_codex("t", &workspace, &codex_thread(&old), None)
        .await
        .unwrap();
    a.register_codex("t", &workspace, &codex_thread(&selected), None)
        .await
        .unwrap();
    a.discover_codex("t", &workspace, &codex_thread(&old))
        .await
        .unwrap();
    let (_, child) = claude(&a, Some(old)).await;
    let key = a.send(&child, "keep", "queue", None).await.unwrap()["messageId"]
        .as_str()
        .unwrap()
        .to_string();
    assert_eq!(
        a.instruction(&mutation(&a, &child, "t", &key, "cancel").await)
            .await
            .unwrap_err(),
        "instruction_forbidden"
    );
    assert_eq!(a.get(&child).await.unwrap().pending.len(), 1);
}

#[tokio::test]
async fn list_rejects_invalid_boundaries_and_expires_old_revision() {
    let (_, a) = fixture().await;
    for options in [
        json!({"limit":0}),
        json!({"limit":501}),
        json!({"taskIds":["bad"]}),
        json!({"workspaceId":"bad"}),
        json!({"status":"bad"}),
        json!({"unknown":true}),
    ] {
        assert!(a.query(options).await.is_err());
    }
    let empty = a.query(json!({"summaryOnly":true})).await.unwrap();
    assert_eq!(empty["delta"], false);
    assert_eq!(empty["unchanged"], false);
    assert_eq!(
        a.query(json!({"sinceRevision":0,"sinceEpoch":empty["epoch"]}))
            .await
            .unwrap()["fullRefreshRequired"],
        true
    );
    let (terminal, task) = claude(&a, None).await;
    let full = a
        .query(json!({"taskIds":[task],"summaryOnly":true}))
        .await
        .unwrap();
    a.send(&task, "one", "queue", None).await.unwrap();
    let other = id();
    let other_base = a.query(json!({"taskIds":[other]})).await.unwrap();
    a.send(&task, "two", "queue", None).await.unwrap();
    let unrelated = a
        .query(
            json!({"taskIds":[other],"sinceRevision":other_base["revision"],"sinceEpoch":other_base["epoch"],"sinceFilter":other_base["filter"]}),
        )
        .await
        .unwrap();
    assert_eq!(unrelated["agents"], json!([]));
    assert_eq!(unrelated["removedTaskIds"], json!([]));
    assert_eq!(unrelated["unchanged"], false);
    assert_eq!(a.query(json!({"taskIds":[other],"summaryOnly":true,"sinceRevision":full["revision"],"sinceEpoch":full["epoch"],"sinceFilter":full["filter"]})).await.unwrap()["reason"], "filter_changed");
    a.close(&terminal).await.unwrap();
}

#[tokio::test]
async fn completed_history_is_count_and_byte_bounded_without_losing_unfinished_work() {
    for body in ["short".to_string(), "large".repeat(2000)] {
        let (store, a) = fixture().await;
        let (_, task) = claude(&a, None).await;
        a.send(&task, "queued work", "queue", None).await.unwrap();
        let mut row = serde_json::to_value(a.get(&task).await.unwrap()).unwrap();
        let mut history: Vec<Value>=(0..200).map(|i| json!({"id":format!("done-{i}"),"text":body,"state":(["consumed","cancelled","superseded"][i%3]),"history":[{"at":format!("2026-10-30T00:00:00.{:03}Z",i),"state":"consumed"}]})).collect();
        for state in ["delivered", "delivering", "unknown"] {
            history.push(
                json!({"id":state,"text":"unprocessed".repeat(30000),"state":state,"history":[]}),
            );
        }
        row["instructions"] = json!(history);
        store
            .call("put", json!({"table":"agents","value":row}))
            .await
            .unwrap();
        let recovered = Agents::new(store.clone(), Arc::new(RuntimeStub::default()))
            .await
            .unwrap();
        let actual = recovered.get(&task).await.unwrap();
        let completed: Vec<_> = actual
            .instructions
            .iter()
            .filter(|m| ["consumed", "cancelled", "superseded"].contains(&m.state.as_str()))
            .collect();
        assert!(completed.len() <= 128);
        assert!(serde_json::to_vec(&completed).unwrap().len() <= 256 * 1024);
        assert!(
            completed
                .iter()
                .map(|m| serde_json::to_vec(m).unwrap().len())
                .sum::<usize>()
                <= 256 * 1024
        );
        assert_eq!(
            actual.instruction_history_pruned,
            200 - completed.len() as u64
        );
        assert_eq!(completed.last().unwrap().id, "done-199");
        for key in ["delivered", "delivering", "unknown"] {
            let m = actual.instructions.iter().find(|m| m.id == key).unwrap();
            assert_eq!(m.text, "unprocessed".repeat(30000));
            assert_eq!(m.state, if key == "delivering" { "unknown" } else { key });
        }
        assert_eq!(actual.pending[0].text, "queued work");
        let persisted = store
            .call("get", json!({"table":"agents","id":task}))
            .await
            .unwrap();
        assert_eq!(persisted, serde_json::to_value(actual).unwrap());
        let again = Agents::new(store, Arc::new(RuntimeStub::default()))
            .await
            .unwrap();
        assert_eq!(
            serde_json::to_value(again.get(&task).await.unwrap()).unwrap(),
            persisted
        );
    }
}

#[tokio::test]
async fn claude_binding_only_close_and_session_end_are_visible_in_deltas() {
    for end in ["close", "SessionEnd"] {
        let (_, a) = fixture().await;
        let (terminal, task) = claude(&a, None).await;
        confirm(&a, &terminal, &task).await;
        event(&a, &terminal, &task, "UserPromptSubmit", json!({})).await;
        a.claude_interrupted(&terminal, true).await.unwrap();
        let baseline = a.query(json!({"summaryOnly":true})).await.unwrap();
        assert_eq!(baseline["currentSessionIds"][&terminal], task);
        let before = a.get(&task).await.unwrap().revision;
        if end == "close" {
            a.close(&terminal).await.unwrap();
        } else {
            assert!(event(&a, &terminal, &task, end, json!({})).await);
        }
        assert_eq!(
            a.get(&task).await.unwrap().revision,
            before,
            "fixture exercises a save no-op"
        );
        let delta=a.query(json!({"summaryOnly":true,"sinceRevision":baseline["revision"],"sinceEpoch":baseline["epoch"],"sinceFilter":baseline["filter"]})).await.unwrap();
        assert_eq!(
            delta["unchanged"], false,
            "binding removal is a list change even without an Agent write"
        );
        assert!(delta["revision"].as_u64().unwrap() > baseline["revision"].as_u64().unwrap());
        assert_eq!(delta["currentSessionIds"], json!({}));
        assert_eq!(delta["removedSessionTerminalIds"], json!([terminal]));
        let mut cached = baseline["currentSessionIds"].as_object().unwrap().clone();
        for id in delta["removedSessionTerminalIds"].as_array().unwrap() {
            cached.remove(id.as_str().unwrap());
        }
        cached.extend(delta["currentSessionIds"].as_object().unwrap().clone());
        assert_eq!(
            json!(cached),
            a.query(json!({"summaryOnly":true})).await.unwrap()["currentSessionIds"]
        );
    }
}

#[tokio::test]
async fn binding_deltas_cover_rebind_resume_filter_and_workspace_tombstones() {
    let (_, a) = fixture().await;
    let (first, task) = claude(&a, None).await;
    let baseline = a.query(json!({"summaryOnly":true})).await.unwrap();
    a.close(&first).await.unwrap();
    let second = id();
    a.prepare_claude(
        json!({"id":"w","path":"/tmp/w","name":"work"}),
        &second,
        Some(task.clone()),
        None,
        None,
    )
    .await
    .unwrap();
    assert!(event(&a, &second, &task, "SessionStart", json!({})).await);
    let resumed=a.query(json!({"summaryOnly":true,"sinceRevision":baseline["revision"],"sinceEpoch":baseline["epoch"],"sinceFilter":baseline["filter"]})).await.unwrap();
    assert_eq!(resumed["removedSessionTerminalIds"], json!([first]));
    assert_eq!(resumed["currentSessionIds"], json!({second.clone():task}));
    let all = a.query(json!({"summaryOnly":true})).await.unwrap();
    let filtered = a
        .query(json!({"taskIds":[task],"summaryOnly":true}))
        .await
        .unwrap();
    let next = id();
    assert!(event(&a, &second, &next, "SessionStart", json!({})).await);
    let changed=a.query(json!({"summaryOnly":true,"sinceRevision":all["revision"],"sinceEpoch":all["epoch"],"sinceFilter":all["filter"]})).await.unwrap();
    assert_eq!(changed["removedSessionTerminalIds"], json!([]));
    assert_eq!(changed["currentSessionIds"], json!({second.clone():next}));
    let hidden=a.query(json!({"taskIds":[task],"summaryOnly":true,"sinceRevision":filtered["revision"],"sinceEpoch":filtered["epoch"],"sinceFilter":filtered["filter"]})).await.unwrap();
    assert_eq!(hidden["removedSessionTerminalIds"], json!([second]));
    assert_eq!(hidden["currentSessionIds"], json!({}));
    let before_delete = a.query(json!({"summaryOnly":true})).await.unwrap();
    a.forget_workspace("w").await;
    let deleted=a.query(json!({"summaryOnly":true,"sinceRevision":before_delete["revision"],"sinceEpoch":before_delete["epoch"],"sinceFilter":before_delete["filter"]})).await.unwrap();
    assert_eq!(deleted["removedTaskIds"].as_array().unwrap().len(), 2);
    assert_eq!(deleted["removedSessionTerminalIds"], json!([second]));
    assert_eq!(deleted["currentSessionIds"], json!({}));
}
