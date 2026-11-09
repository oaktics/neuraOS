use super::*;
use axum::{
    extract::State,
    http::StatusCode,
    routing::{get, post},
    Json, Router,
};
use std::sync::Mutex as StdMutex;

const WORKSPACE: &str = "11111111-1111-4111-8111-111111111111";
const JOB: &str = "22222222-2222-4222-8222-222222222222";
struct Fixture {
    job: Value,
    jobs_supported: bool,
    present: bool,
    complete_on_read: bool,
    fail_read: bool,
    stall_read: bool,
    stall_start: bool,
    stall_state: bool,
    next_job: Option<Value>,
    commands: Vec<Value>,
}
fn job(status: &str) -> Value {
    json!({"id":JOB,"workspaceId":WORKSPACE,"status":status,"phase":"remove-files","revision":1,"retryable":true,"blocksWorkspace":true,"verifiedAbsent":status=="succeeded"})
}
async fn fixture(status: &str) -> (Client, Arc<StdMutex<Fixture>>, tokio::task::JoinHandle<()>) {
    let state = Arc::new(StdMutex::new(Fixture {
        job: job(status),
        jobs_supported: true,
        present: true,
        complete_on_read: false,
        fail_read: false,
        stall_read: false,
        stall_start: false,
        stall_state: false,
        next_job: None,
        commands: vec![],
    }));
    let app = Router::new()
        .route("/v1/state", get(|State(state): State<Arc<StdMutex<Fixture>>>| async move {
            let stall = state.lock().unwrap().stall_state;
            if stall { std::future::pending::<()>().await; }
            let state = state.lock().unwrap();
            Json(json!({"features":if state.jobs_supported {vec!["workspace.delete.jobs"]} else {vec![]},"workspaces":if state.present {vec![json!({"id":WORKSPACE})]} else {vec![]}}))
        }))
        .route("/v1/commands", post(|State(state): State<Arc<StdMutex<Fixture>>>, Json(body): Json<Value>| async move {
            let stall = {
                let mut state = state.lock().unwrap();
                state.commands.push(body);
                state.stall_start
            };
            if stall { std::future::pending::<()>().await; }
            Json(json!({"ok":true,"accepted":true,"job":state.lock().unwrap().job}))
        }))
        .route("/v1/workspace-deletions/{id}", get(|State(state): State<Arc<StdMutex<Fixture>>>| async move {
            let stall = state.lock().unwrap().stall_read;
            if stall { std::future::pending::<()>().await; }
            let mut state = state.lock().unwrap();
            if state.fail_read {return (StatusCode::SERVICE_UNAVAILABLE,Json(json!({"error":"offline"})))}
            if state.complete_on_read {state.job=job("succeeded");state.present=false;}
            (StatusCode::OK, Json(state.next_job.clone().unwrap_or_else(|| state.job.clone())))
        }))
        .with_state(state.clone());
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let endpoint =
        reqwest::Url::parse(&format!("http://{}", listener.local_addr().unwrap())).unwrap();
    let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let client = Client {
        http: reqwest::Client::new(),
        endpoint,
        token: "fixture".into(),
        terminal: "terminal".into(),
        workspace: "33333333-3333-4333-8333-333333333333".into(),
        channel_token: String::new(),
        browser_token: String::new(),
        changes: watch::channel(0).1,
        channel_changes: watch::channel(0).1,
    };
    (client, state, server)
}
fn deletion_args() -> Value {
    json!({"operationId":JOB,"workspaceId":WORKSPACE,"expectedHead":"a".repeat(40),"mergedPR":151})
}

#[tokio::test]
async fn accepted_job_is_not_completion_and_status_reads_never_retry() {
    let (client, state, server) = fixture("running").await;
    let pending = client
        .call("workspace_deletion_status", json!({"jobId":JOB}))
        .await
        .unwrap();
    assert_eq!(pending["accepted"], true);
    assert_eq!(pending["completed"], false);
    assert_eq!(pending["verifiedAbsent"], false);
    assert_eq!(pending["workspacePresent"], true);
    assert!(state.lock().unwrap().commands.is_empty());
    state.lock().unwrap().job = job("failed");
    let error = client
        .call("workspace_deletion_status", json!({"jobId":JOB}))
        .await
        .unwrap_err();
    let error: Value = serde_json::from_str(&error).unwrap();
    assert_eq!(error["jobId"], JOB);
    assert_eq!(error["completed"], false);
    assert!(state.lock().unwrap().commands.is_empty());
    server.abort();
}
#[tokio::test]
async fn delete_uses_safe_durable_start_and_verifies_completion_independently() {
    let (client, state, server) = fixture("queued").await;
    state.lock().unwrap().complete_on_read = true;
    let result = client
        .call("workspace_delete", deletion_args())
        .await
        .unwrap();
    assert_eq!(result["completed"], true);
    assert_eq!(result["verifiedAbsent"], true);
    let commands = &state.lock().unwrap().commands;
    assert_eq!(commands.len(), 1);
    assert_eq!(commands[0]["command"]["type"], "workspace.delete.start");
    assert_eq!(commands[0]["command"]["discardChanges"], false);
    assert_eq!(
        commands[0]["command"]["cleanup"]["expectedHead"],
        "a".repeat(40)
    );
    server.abort();
}
#[tokio::test]
async fn status_transport_failure_retains_accepted_job_for_recovery() {
    let (client, state, server) = fixture("running").await;
    state.lock().unwrap().fail_read = true;
    let result = client
        .call("workspace_delete", deletion_args())
        .await
        .unwrap();
    assert_eq!(result["jobId"], JOB);
    assert_eq!(result["completed"], false);
    assert!(result["statusError"].is_string());
    assert_eq!(state.lock().unwrap().commands.len(), 1);
    server.abort();
}
#[tokio::test]
async fn completion_requires_both_backend_proof_and_workspace_absence() {
    let (client, state, server) = fixture("succeeded").await;
    assert!(client
        .call("workspace_deletion_status", json!({"jobId":JOB}))
        .await
        .unwrap_err()
        .contains("cleanup_unconfirmed"));
    {
        let mut state = state.lock().unwrap();
        state.present = false;
        state.job["verifiedAbsent"] = json!(false);
    }
    assert!(client
        .call("workspace_deletion_status", json!({"jobId":JOB}))
        .await
        .unwrap_err()
        .contains("cleanup_unconfirmed"));
    assert!(client
        .call("workspace_deletion_status", json!({"jobId":"../state"}))
        .await
        .is_err());
    assert!(client
        .call(
            "workspace_deletion_status",
            json!({"jobId":JOB,"waitMs":25001})
        )
        .await
        .is_err());
    assert!(state.lock().unwrap().commands.is_empty());
    server.abort();
}

#[tokio::test]
async fn accepted_status_stall_returns_last_job_within_budget() {
    let (client, state, server) = fixture("running").await;
    state.lock().unwrap().stall_read = true;
    let original = job("running");
    let result = tokio::time::timeout(
        Duration::from_secs(1),
        client.await_deletion(original.clone(), WORKSPACE, Duration::from_millis(30)),
    )
    .await
    .unwrap()
    .unwrap();
    assert_eq!(result["job"], original);
    assert_eq!(result["completed"], false);
    assert_eq!(result["statusError"], "deletion_status_timeout");
    assert!(state.lock().unwrap().commands.is_empty());
    server.abort();
}

#[tokio::test]
async fn proof_stall_is_bounded_and_preserves_pending_and_failed_job() {
    let (client, state, server) = fixture("running").await;
    state.lock().unwrap().stall_state = true;
    let pending = job("running");
    let failed = job("failed");
    let succeeded = job("succeeded");
    let (a, b, c) = tokio::time::timeout(Duration::from_secs(3), async {
        tokio::join!(
            client.deletion_result(pending.clone()),
            client.deletion_result(failed.clone()),
            client.deletion_result(succeeded.clone())
        )
    })
    .await
    .unwrap();
    let a = a.unwrap();
    assert_eq!(a["job"], pending);
    assert_eq!(a["completed"], false);
    assert_eq!(a["proofError"], "deletion_proof_timeout");
    let b: Value = serde_json::from_str(&b.unwrap_err()).unwrap();
    assert_eq!(b["job"], failed);
    assert_eq!(b["proofError"], "deletion_proof_timeout");
    let c: Value = serde_json::from_str(&c.unwrap_err()).unwrap();
    assert_eq!(c["error"], "cleanup_unconfirmed");
    assert_eq!(c["result"]["job"], succeeded);
    assert_eq!(c["result"]["completed"], false);
    server.abort();
}

#[tokio::test]
async fn status_stall_without_a_known_job_is_bounded() {
    let (client, state, server) = fixture("running").await;
    state.lock().unwrap().stall_read = true;
    let error = tokio::time::timeout(
        Duration::from_secs(3),
        client.call("workspace_deletion_status", json!({"jobId":JOB})),
    )
    .await
    .unwrap()
    .unwrap_err();
    let error: Value = serde_json::from_str(&error).unwrap();
    assert_eq!(error["jobId"], JOB);
    assert_eq!(error["error"], "deletion_status_timeout");
    server.abort();
}

#[tokio::test]
async fn start_rejects_unrelated_workspace_but_accepts_old_duplicate_job_id() {
    let (client, state, server) = fixture("succeeded").await;
    let other = "44444444-4444-4444-8444-444444444444";
    state.lock().unwrap().job["workspaceId"] = json!(other);
    let error = client
        .call("workspace_delete", deletion_args())
        .await
        .unwrap_err();
    let error: Value = serde_json::from_str(&error).unwrap();
    assert_eq!(error["error"], "invalid_deletion_job");
    assert_eq!(error["expectedWorkspaceId"], WORKSPACE);
    assert_eq!(error["job"]["workspaceId"], other);
    {
        let mut state = state.lock().unwrap();
        state.job = job("succeeded");
        state.job["id"] = json!(other);
        state.present = false;
    }
    let result = client
        .call("workspace_delete", deletion_args())
        .await
        .unwrap();
    assert_eq!(result["jobId"], other);
    assert_eq!(result["completed"], true);
    server.abort();
}

#[tokio::test]
async fn poll_rejects_changed_job_or_workspace_and_preserves_last_known_job() {
    let (client, state, server) = fixture("running").await;
    let original = job("running");
    for field in ["id", "workspaceId"] {
        let mut wrong = job("succeeded");
        wrong[field] = json!("44444444-4444-4444-8444-444444444444");
        state.lock().unwrap().next_job = Some(wrong.clone());
        let result = client
            .await_deletion(original.clone(), WORKSPACE, Duration::from_secs(1))
            .await
            .unwrap();
        assert_eq!(result["completed"], false);
        assert_eq!(result["job"], original);
        let error: Value = serde_json::from_str(result["statusError"].as_str().unwrap()).unwrap();
        assert_eq!(error["job"], wrong);
    }
    state.lock().unwrap().next_job.as_mut().unwrap()["id"] =
        json!("44444444-4444-4444-8444-444444444444");
    let error = client
        .call("workspace_deletion_status", json!({"jobId":JOB}))
        .await
        .unwrap_err();
    let error: Value = serde_json::from_str(&error).unwrap();
    assert_eq!(error["expectedJobId"], JOB);
    assert_eq!(error["job"]["status"], "succeeded");
    assert!(state.lock().unwrap().commands.is_empty());
    server.abort();
}

#[tokio::test]
async fn start_stall_retains_operation_without_inventing_acceptance_or_job() {
    let (client, state, server) = fixture("running").await;
    state.lock().unwrap().stall_start = true;
    let error = tokio::time::timeout(
        Duration::from_secs(17),
        client.call("workspace_delete", deletion_args()),
    )
    .await
    .unwrap()
    .unwrap_err();
    let error: Value = serde_json::from_str(&error).unwrap();
    assert_eq!(error["error"], "deletion_start_uncertain");
    assert_eq!(error["operationId"], JOB);
    assert_eq!(error["workspaceId"], WORKSPACE);
    assert_eq!(error["outcome"], "unknown");
    assert_eq!(error["completed"], false);
    assert!(error.get("accepted").is_none());
    assert!(error.get("jobId").is_none());
    assert!(error["recovery"]
        .as_str()
        .unwrap()
        .contains("same operationId"));
    assert_eq!(state.lock().unwrap().commands.len(), 1);
    server.abort();
}

#[tokio::test]
async fn feature_stall_is_bounded_without_sending_start() {
    let (client, state, server) = fixture("running").await;
    state.lock().unwrap().stall_state = true;
    let error = tokio::time::timeout(
        Duration::from_secs(17),
        client.call("workspace_delete", deletion_args()),
    )
    .await
    .unwrap()
    .unwrap_err();
    let error: Value = serde_json::from_str(&error).unwrap();
    assert_eq!(error["error"], "deletion_feature_timeout");
    assert_eq!(error["operationId"], JOB);
    assert_eq!(error["workspaceId"], WORKSPACE);
    assert_eq!(error["startRequestSent"], false);
    assert!(state.lock().unwrap().commands.is_empty());
    server.abort();
}

#[tokio::test]
async fn old_daemon_keeps_legacy_command_and_absence_verification() {
    let (client, state, server) = fixture("succeeded").await;
    {
        let mut state = state.lock().unwrap();
        state.jobs_supported = false;
        state.present = false;
        state.fail_read = true;
    }
    let result = client
        .call("workspace_delete", deletion_args())
        .await
        .unwrap();
    assert_eq!(result["verifiedAbsent"], true);
    assert_eq!(state.lock().unwrap().commands.len(), 1);
    assert_eq!(
        state.lock().unwrap().commands[0]["command"]["type"],
        "workspace.delete"
    );
    assert_eq!(
        state.lock().unwrap().commands[0]["command"]["discardChanges"],
        false
    );
    server.abort();
}
