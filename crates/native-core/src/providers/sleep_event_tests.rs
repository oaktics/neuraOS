use super::*;
use crate::providers::event_queue;

// Match CodexRpc's notification path, including its filter and bounded queue.
// Calling codex_event directly would miss a dropped wire notification.
async fn notification(agents: &Agents, workspace: &Value, value: Value) {
    assert!(value.get("id").is_none());
    let filtered =
        event_queue::supervision_event(value).expect("lifecycle notification was filtered");
    let (tx, mut rx) = event_queue::channel();
    tx.send(filtered);
    let event = tokio::time::timeout(std::time::Duration::from_secs(1), rx.recv())
        .await
        .unwrap()
        .unwrap();
    assert_ne!(event["method"], "neura/overflow");
    agents.codex_event("t", workspace, &event).await.unwrap();
}

#[tokio::test]
async fn idless_provider_errors_reach_runtime_issue_through_supervision_queue() {
    let (_, agents) = fixture().await;
    let task = id();
    let workspace = json!({"id":"w","path":"/tmp/w"});
    notification(
        &agents,
        &workspace,
        json!({"method":"thread/started","params":{"thread":codex_thread(&task)}}),
    )
    .await;
    notification(
        &agents,
        &workspace,
        json!({"method":"turn/started","params":{"threadId":task,"turn":{"id":"turn1"}}}),
    )
    .await;
    for will_retry in [true, false] {
        notification(
            &agents,
            &workspace,
            json!({"method":"error","params":{
                "threadId":task,"turnId":"turn1","willRetry":will_retry,
                "error":{"message":"SECRET-provider-response".repeat(10000)}
            }}),
        )
        .await;
        let page = agents.query(json!({"summaryOnly":true})).await.unwrap();
        let row = &page["agents"][0];
        assert_eq!(row["status"], "working");
        assert_eq!(row["runtimeIssue"]["willRetry"], will_retry);
        assert_eq!(row["runtimeIssue"]["turnId"], "turn1");
        assert!(row["runtimeIssue"]["id"].is_string());
        assert!(!page.to_string().contains("SECRET"));
    }
    let issue = agents.get(&task).await.unwrap().runtime_issue.unwrap().id;
    notification(&agents, &workspace, json!({"method":"turn/completed","params":{"threadId":task,"turn":{"id":"turn1","status":"completed"}}})).await;
    let recovered = agents.get(&task).await.unwrap();
    assert_eq!(recovered.status, "idle");
    assert_eq!(recovered.last_turn_status.as_deref(), Some("completed"));
    assert_eq!(recovered.runtime_issue.unwrap().id, issue);
}

#[tokio::test]
async fn history_turn_outcomes_waiting_and_disconnect_survive_supervision_filter() {
    let (_, agents) = fixture().await;
    let task = id();
    let workspace = json!({"id":"w","path":"/tmp/w"});
    notification(
        &agents,
        &workspace,
        json!({"method":"thread/started","params":{"thread":codex_thread(&task)}}),
    )
    .await;
    for (index, outcome) in ["failed", "interrupted", "completed"]
        .into_iter()
        .enumerate()
    {
        let turn = format!("turn{index}");
        notification(
            &agents,
            &workspace,
            json!({"method":"turn/started","params":{"threadId":task,"turn":{"id":turn}}}),
        )
        .await;
        assert_eq!(agents.get(&task).await.unwrap().status, "working");
        notification(&agents, &workspace, json!({"method":"thread/status/changed","params":{"threadId":task,"status":{"type":"active","activeFlags":["waitingOnUserInput"]}}})).await;
        assert_eq!(agents.get(&task).await.unwrap().status, "waiting");
        notification(&agents, &workspace, json!({"method":"turn/completed","params":{"threadId":task,"turn":{"id":turn,"status":outcome,"items":[]}}})).await;
        let state = agents.get(&task).await.unwrap();
        assert_eq!(
            state.status,
            if outcome == "completed" {
                "idle"
            } else {
                outcome
            }
        );
        assert_eq!(state.last_turn_status.as_deref(), Some(outcome));
        assert_eq!(state.last_turn_id.as_deref(), Some(turn.as_str()));
    }
    // CodexRpc also emits this directly on transport EOF.
    notification(&agents, &workspace, json!({"method":"neura/disconnected"})).await;
    let page = agents.query(json!({"summaryOnly":true})).await.unwrap();
    assert_eq!(page["agents"][0]["providerConnection"], "disconnected");
    assert_eq!(page["agents"][0]["status"], "interrupted");
    assert_eq!(page["agents"][0]["lastTurnStatus"], "completed");
    for method in [
        "item/agentMessage/delta",
        "item/commandExecution/outputDelta",
        "thread/tokenUsage/updated",
        "unrelated/event",
    ] {
        assert!(event_queue::supervision_event(json!({"method":method,"params":{}})).is_none());
    }
}
