//! Production API and production-daemon restart against isolated repositories.
use neura_native_core::{
    browser, contracts, diagnostics, error, events, github, mutation, process_tree, providers, pty,
    store, usage, workspace,
};
#[path = "../src/server.rs"]
#[allow(dead_code)]
mod server;
use serde_json::{json, Value};
use std::{
    path::{Path, PathBuf},
    sync::Arc,
    time::{Duration, Instant},
};
fn uuid() -> String {
    uuid::Uuid::new_v4().to_string()
}
fn binary() -> &'static str {
    env!("CARGO_BIN_EXE_neura-native-core")
}
async fn fixture(dir: &Path) -> (Arc<server::AppState>, Value, Value) {
    std::fs::create_dir_all(dir.join("data")).unwrap();
    let repo = dir.join("repo");
    std::fs::create_dir(&repo).unwrap();
    let root = repo.to_str().unwrap();
    for args in [
        vec!["init", "-b", "main"],
        vec!["config", "user.name", "Fixture"],
        vec!["config", "user.email", "fixture@example.invalid"],
        vec!["config", "core.hooksPath", "/dev/null"],
        vec!["config", "commit.gpgsign", "false"],
    ] {
        workspace::git(root, &args).await.unwrap();
    }
    std::fs::write(repo.join("file"), "original").unwrap();
    std::fs::write(repo.join(".gitignore"), "ignored/\n").unwrap();
    workspace::git(root, &["add", "."]).await.unwrap();
    workspace::git(root, &["commit", "-m", "fixture"])
        .await
        .unwrap();
    let project = uuid();
    let w = uuid();
    let target = dir.join("tree");
    workspace::git(
        root,
        &["worktree", "add", "-b", "fixture", target.to_str().unwrap()],
    )
    .await
    .unwrap();
    let state = server::AppState::new(
        dir.join("data"),
        "fixture".into(),
        "http://127.0.0.1:1".into(),
    )
    .await
    .unwrap();
    let project = json!({"id":project,"name":"fixture","path":repo,"isGit":true});
    let w = json!({"id":w,"name":"fixture","projectId":project["id"],"path":target,"kind":"worktree","branch":"fixture"});
    state
        .store
        .put("projects", project.clone(), None)
        .await
        .unwrap();
    state
        .store
        .put("workspaces", w.clone(), None)
        .await
        .unwrap();
    (state, project, w)
}
async fn listen(state: Arc<server::AppState>) -> (String, tokio::task::JoinHandle<()>) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let server =
        tokio::spawn(async move { axum::serve(listener, server::router(state)).await.unwrap() });
    (base, server)
}
async fn cmd(base: &str, op: &str, command: Value) -> (u16, Value) {
    let response = reqwest::Client::new()
        .post(format!("{base}/v1/commands"))
        .bearer_auth("fixture")
        .json(&json!({"operationId":op,"command":command}))
        .send()
        .await
        .unwrap();
    (response.status().as_u16(), response.json().await.unwrap())
}
async fn get(base: &str, id: &str) -> Value {
    let response = reqwest::Client::new()
        .get(format!("{base}/v1/workspace-deletions/{id}"))
        .bearer_auth("fixture")
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 200);
    response.json().await.unwrap()
}
async fn finished(base: &str, id: &str) -> Value {
    tokio::time::timeout(Duration::from_secs(40), async {
        loop {
            let j = get(base, id).await;
            if ["succeeded", "failed"].contains(&j["status"].as_str().unwrap()) {
                return j;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap()
}
fn deletion(w: &Value) -> Value {
    json!({"type":"workspace.delete.start","workspaceId":w["id"],"stopTerminals":true,"discardChanges":false})
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn jobs_cutoff_admission_idempotency_retry_and_bounded_purge() {
    let temp = std::env::temp_dir().join(format!("neura-delete-api-{}", uuid()));
    std::fs::create_dir(&temp).unwrap();
    let dir = std::fs::canonicalize(temp).unwrap();
    process_tree::ensure_supervisor(Path::new(binary()), &dir.join("owner.lock"))
        .await
        .unwrap();
    let (s, project, w) = fixture(&dir).await;
    let (base, http) = listen(s.clone()).await;
    let root = Path::new(w["path"].as_str().unwrap());
    // Safe failure releases admission; explicit retry keeps options/generation.
    std::fs::write(root.join("file"), "dirty").unwrap();
    let op = uuid();
    let (status, accepted) = cmd(&base, &op, deletion(&w)).await;
    assert_eq!(status, 200, "{accepted}");
    assert_eq!(accepted["job"]["generation"], 1);
    let failed = finished(&base, &op).await;
    assert_eq!(failed["error"]["code"], "workspace_dirty");
    assert_eq!(failed["blocksWorkspace"], false);
    assert_eq!(get(&base, &op).await["id"], op);
    // Different options must be a new authorized attempt, never mutate a job.
    let retry = uuid();
    let (status, retried) = cmd(
        &base,
        &retry,
        json!({"type":"workspace.deletion.retry","jobId":op}),
    )
    .await;
    assert_eq!(status, 200, "{retried}");
    assert_eq!(retried["job"]["generation"], 1);
    assert_eq!(
        finished(&base, &op).await["error"]["code"],
        "workspace_dirty"
    );
    let repeat = cmd(
        &base,
        &retry,
        json!({"type":"workspace.deletion.retry","jobId":op}),
    )
    .await
    .1;
    assert_eq!(
        repeat["job"]["status"], "failed",
        "same retry operation must not restart again"
    );
    workspace::git(root.to_str().unwrap(), &["restore", "file"])
        .await
        .unwrap();
    // Thousands of ignored files + output exercise physical deletion and batched DB purge.
    std::fs::create_dir(root.join("ignored")).unwrap();
    for n in 0..3000 {
        std::fs::write(root.join("ignored").join(n.to_string()), b"fixture").unwrap();
    }
    let terminal = uuid();
    s.store
        .put(
            "terminals",
            json!({"id":terminal,"workspaceId":w["id"],"provider":"shell","status":"exited"}),
            None,
        )
        .await
        .unwrap();
    for _ in 0..40 {
        s.store
            .call(
                "append",
                json!((0..128)
                    .map(|_| json!({"terminalId":terminal,"data":"x".repeat(4096)}))
                    .collect::<Vec<_>>()),
            )
            .await
            .unwrap();
    }
    // Foreign workspace shares the project but must stay admitted and retain data.
    let foreign = uuid();
    s.store
        .put(
            "workspaces",
            json!({"id":foreign,"projectId":project["id"],"path":project["path"],"kind":"root"}),
            None,
        )
        .await
        .unwrap();
    let foreign_terminal = uuid();
    s.store
        .put(
            "terminals",
            json!({"id":foreign_terminal,"workspaceId":foreign,"status":"exited"}),
            None,
        )
        .await
        .unwrap();
    s.store
        .call(
            "append",
            json!([{"terminalId":foreign_terminal,"data":"keep"}]),
        )
        .await
        .unwrap();
    let delete_id = uuid();
    let (entered, release) = server::deletion::pause_fixture(&s, &delete_id).await;
    let mut request = deletion(&w);
    request["discardChanges"] = json!(true);
    // Hold an already-admitted mutation. Acceptance cannot pass this lease.
    let lease = mutation::workspace_activity(w["id"].as_str().unwrap()).await;
    let task = tokio::spawn({
        let base = base.clone();
        let id = delete_id.clone();
        let c = request.clone();
        async move { cmd(&base, &id, c).await }
    });
    tokio::time::sleep(Duration::from_millis(30)).await;
    assert!(!task.is_finished());
    drop(lease);
    let (status, accepted) = task.await.unwrap();
    assert_eq!(status, 200, "{accepted}");
    entered.notified().await;
    assert_eq!(accepted["job"]["generation"], 2);
    assert_eq!(
        s.store
            .call("workspace_deletion_gate", json!({"workspaceId":w["id"]}))
            .await
            .unwrap()["blocked"],
        true
    );
    assert_eq!(
        s.store
            .call("workspace_deletion_gate", json!({"workspaceId":foreign}))
            .await
            .unwrap()["blocked"],
        false
    );
    let mut open = json!({"type":"terminal.open","workspaceId":w["id"],"provider":"shell"});
    assert_eq!(
        cmd(&base, &uuid(), open.clone()).await.1["error"],
        "workspace_deleting"
    );
    open = json!({"type":"file.save","workspaceId":w["id"],"path":"file","content":"bad","expectedHash":workspace::hash("original")});
    assert_eq!(
        cmd(&base, &uuid(), open).await.1["error"],
        "workspace_deleting"
    );
    let duplicate = cmd(&base, &uuid(), request.clone()).await.1;
    assert_eq!(duplicate["job"]["id"], delete_id);
    let repeated = cmd(&base, &delete_id, request.clone()).await.1;
    assert_eq!(repeated["job"]["id"], delete_id);
    assert!(repeated["job"].get("fence").is_none());
    assert!(repeated["job"].get("command").is_none());
    let mut conflict = request.clone();
    conflict["discardChanges"] = json!(false);
    assert_eq!(
        cmd(&base, &delete_id, conflict).await.1["error"],
        "operation_conflict"
    );
    // Legacy caller disconnects while waiting; the existing durable job continues.
    let legacy = tokio::spawn({
        let base = base.clone();
        let mut request = request.clone();
        request["type"] = json!("workspace.delete");
        async move { cmd(&base, &uuid(), request).await }
    });
    tokio::time::sleep(Duration::from_millis(30)).await;
    assert!(!legacy.is_finished());
    legacy.abort();
    let _ = legacy.await;
    // Longpoll is not completed by unrelated output/state invalidations.
    let longpoll = tokio::spawn({
        let base = base.clone();
        let id = delete_id.clone();
        let rev = get(&base, &delete_id).await["revision"].clone();
        async move {
            reqwest::Client::new()
                .get(format!(
                    "{base}/v1/workspace-deletions/{id}?waitMs=25000&afterRevision={rev}"
                ))
                .bearer_auth("fixture")
                .send()
                .await
                .unwrap()
                .json::<Value>()
                .await
                .unwrap()
        }
    });
    for _ in 0..20 {
        s.store
            .call(
                "append",
                json!([{"terminalId":foreign_terminal,"data":"."}]),
            )
            .await
            .unwrap();
    }
    tokio::time::sleep(Duration::from_millis(30)).await;
    assert!(!longpoll.is_finished());
    let deleting = Instant::now();
    release.notify_one();
    let mut worst = Duration::ZERO;
    let mut probes = 0;
    while get(&base, &delete_id).await["status"] != "succeeded" {
        let start = Instant::now();
        s.store.get("workspaces", &foreign).await.unwrap().unwrap();
        s.store
            .call(
                "append",
                json!([{"terminalId":foreign_terminal,"data":"probe"}]),
            )
            .await
            .unwrap();
        worst = worst.max(start.elapsed());
        probes += 1;
        assert!(deleting.elapsed() < Duration::from_secs(30));
        tokio::task::yield_now().await;
    }
    assert!(
        longpoll.await.unwrap()["revision"].as_u64().unwrap()
            > accepted["job"]["revision"].as_u64().unwrap()
    );
    let done = get(&base, &delete_id).await;
    assert_eq!(done["verifiedAbsent"], true);
    assert_eq!(done["blocksWorkspace"], false);
    assert!(!root.exists());
    assert!(Path::new(project["path"].as_str().unwrap())
        .join("file")
        .exists());
    assert!(s
        .store
        .call("output", json!({"terminalId":foreign_terminal,"after":0}))
        .await
        .unwrap()["data"]
        .as_str()
        .unwrap()
        .starts_with("keep"));
    assert_eq!(s.store.call("query",json!({"sql":"SELECT COUNT(*) AS n FROM output WHERE terminalId=?","args":[terminal]})).await.unwrap()[0]["n"],0);
    assert!(
        worst < Duration::from_secs(1),
        "shared writer stalled: {worst:?}"
    );
    eprintln!(
        "3000 files + 20 MiB output deletion: {:?}, foreign probes={probes}, worst={worst:?}",
        deleting.elapsed()
    );
    assert_eq!(
        cmd(&base, &delete_id, request).await.1["job"]["status"],
        "succeeded"
    );
    s.shutdown().await.unwrap();
    http.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn crash_seed_child() {
    let Some(dir) = std::env::var_os("NEURA_DELETE_SEED_DIR") else {
        return;
    };
    let dir = PathBuf::from(dir);
    process_tree::ensure_supervisor(
        Path::new(binary()),
        &dir.join("data/process-supervisor.lock"),
    )
    .await
    .unwrap();
    let (s, _p, w) = fixture(&dir).await;
    let id = std::env::var("NEURA_DELETE_SEED_JOB").unwrap();
    let mut c = deletion(&w);
    c["type"] = json!("workspace.delete");
    s.store
        .call(
            "workspace_deletion_accept",
            json!({"operationId":id,"hash":workspace::hash(&c.to_string()),"command":c}),
        )
        .await
        .unwrap();
    server::deletion::seed_crash_fixture(
        &s,
        &id,
        &std::env::var("NEURA_DELETE_SEED_WINDOW").unwrap(),
    )
    .await
    .unwrap();
    // No graceful shutdown: production restart must recover durable state.
    std::process::exit(77);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn production_restart_recovers_each_destructive_boundary_and_preserves_replacements() {
    for window in [
        "before-move",
        "rename-before-metadata",
        "after-move",
        "removal-intent",
        "partial-files",
        "files-removed",
        "metadata-removed",
        "replacement",
        "symlink",
    ] {
        let temp = std::env::temp_dir().join(format!("neura-delete-crash-{}", uuid()));
        std::fs::create_dir(&temp).unwrap();
        let dir = std::fs::canonicalize(temp).unwrap();
        std::fs::create_dir(dir.join("data")).unwrap();
        let id = uuid();
        let seed = if ["replacement", "symlink"].contains(&window) {
            "partial-files"
        } else {
            window
        };
        let status = tokio::process::Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "crash_seed_child", "--nocapture"])
            .env("NEURA_DELETE_SEED_DIR", &dir)
            .env("NEURA_DELETE_SEED_JOB", &id)
            .env("NEURA_DELETE_SEED_WINDOW", seed)
            .status()
            .await
            .unwrap();
        assert_eq!(status.code(), Some(77));
        let target = dir.join(format!(".neura-delete-{id}"));
        let source = dir.join("tree");
        if window == "replacement" {
            std::fs::create_dir(&source).unwrap();
            std::fs::write(source.join("keep"), "foreign").unwrap();
        }
        let kept = dir.join("foreign");
        if window == "symlink" {
            std::fs::rename(&target, &kept).unwrap();
            std::os::unix::fs::symlink(&kept, &target).unwrap();
            std::fs::write(kept.join("keep"), "foreign").unwrap();
        }
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        drop(listener);
        std::fs::write(dir.join("data/daemon-token"), "fixture").unwrap();
        let mut daemon = tokio::process::Command::new(binary())
            .env("NEURA_DEV_DATA_DIR", dir.join("data"))
            .env("NEURA_DEV_PORT", port.to_string())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .kill_on_drop(true)
            .spawn()
            .unwrap();
        let base = format!("http://127.0.0.1:{port}");
        tokio::time::timeout(Duration::from_secs(10), async {
            loop {
                if let Ok(r) = reqwest::Client::new()
                    .get(format!("{base}/v1/state"))
                    .bearer_auth("fixture")
                    .send()
                    .await
                {
                    if r.status() == 200 {
                        break;
                    }
                }
                assert!(daemon.try_wait().unwrap().is_none());
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
        })
        .await
        .unwrap();
        let result = finished(&base, &id).await;
        if ["replacement", "symlink"].contains(&window) {
            assert_eq!(result["status"], "failed", "{window}: {result}");
            assert_eq!(result["blocksWorkspace"], true);
            assert_eq!(result["retryable"], false);
            assert_eq!(result["error"]["code"], "deletion_identity_changed");
            assert_eq!(
                std::fs::read_to_string(if window == "replacement" {
                    source.join("keep")
                } else {
                    kept.join("keep")
                })
                .unwrap(),
                "foreign"
            );
        } else {
            assert_eq!(result["status"], "succeeded", "{window}: {result}");
            assert_eq!(result["verifiedAbsent"], true);
            assert!(!source.exists());
            assert!(!target.exists());
        }
        unsafe { libc::kill(daemon.id().unwrap() as i32, libc::SIGTERM) };
        assert!(tokio::time::timeout(Duration::from_secs(10), daemon.wait())
            .await
            .unwrap()
            .unwrap()
            .success());
        eprintln!("restart boundary {window}: {}", result["status"]);
    }
}
