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
    present: bool,
    complete_on_read: bool,
    fail_read: bool,
    commands: Vec<Value>,
}
fn job(status: &str) -> Value {
    json!({"id":JOB,"workspaceId":WORKSPACE,"status":status,"phase":"remove-files","revision":1,"retryable":true,"blocksWorkspace":true,"verifiedAbsent":status=="succeeded"})
}
async fn fixture(status: &str) -> (Client, Arc<StdMutex<Fixture>>, tokio::task::JoinHandle<()>) {
    let state = Arc::new(StdMutex::new(Fixture {
        job: job(status),
        present: true,
        complete_on_read: false,
        fail_read: false,
        commands: vec![],
    }));
    let app = Router::new()
        .route("/v1/state", get(|State(state): State<Arc<StdMutex<Fixture>>>| async move {
            let state = state.lock().unwrap();
            Json(json!({"features":["workspace.delete.jobs"],"workspaces":if state.present {vec![json!({"id":WORKSPACE})]} else {vec![]}}))
        }))
        .route("/v1/commands", post(|State(state): State<Arc<StdMutex<Fixture>>>, Json(body): Json<Value>| async move {
            let mut state = state.lock().unwrap();
            state.commands.push(body);
            Json(json!({"ok":true,"accepted":true,"job":state.job}))
        }))
        .route("/v1/workspace-deletions/{id}", get(|State(state): State<Arc<StdMutex<Fixture>>>| async move {
            let mut state = state.lock().unwrap();
            if state.fail_read {return (StatusCode::SERVICE_UNAVAILABLE,Json(json!({"error":"offline"})))}
            if state.complete_on_read {state.job=job("succeeded");state.present=false;}
            (StatusCode::OK, Json(state.job.clone()))
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
