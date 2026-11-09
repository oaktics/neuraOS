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

async fn approved_read_only_directories_are_removed_without_changing_external_targets() {
    use std::os::unix::fs::PermissionsExt;
    let temp = std::env::temp_dir().join(format!("neura-delete-readonly-{}", uuid()));
    std::fs::create_dir(&temp).unwrap();
    let dir = std::fs::canonicalize(temp).unwrap();
    let (s, _, w) = fixture(&dir).await;
    let (base, http) = listen(s.clone()).await;
    let source = Path::new(w["path"].as_str().unwrap());
    let readonly = source.join("ignored/checkouts");
    std::fs::create_dir_all(readonly.join("nested")).unwrap();
    std::fs::write(readonly.join("nested/cache"), "generated").unwrap();
    let external = dir.join("external");
    std::fs::create_dir(&external).unwrap();
    std::fs::write(external.join("keep"), "foreign").unwrap();
    std::os::unix::fs::symlink(&external, readonly.join("external-link")).unwrap();
    for path in [&readonly, &readonly.join("nested"), &external] {
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o500)).unwrap();
    }
    let guarded = uuid();
    assert_eq!(cmd(&base, &guarded, deletion(&w)).await.0, 200);
    let failed = finished(&base, &guarded).await;
    assert_eq!(failed["error"]["code"], "workspace_ignored_files");
    assert_eq!(
        std::fs::metadata(&readonly).unwrap().permissions().mode() & 0o777,
        0o500
    );
    assert_eq!(
        std::fs::read_to_string(readonly.join("nested/cache")).unwrap(),
        "generated"
    );

    let approved = uuid();
    let mut command = deletion(&w);
    command["discardChanges"] = json!(true);
    assert_eq!(cmd(&base, &approved, command).await.0, 200);
    let result = finished(&base, &approved).await;
    assert_eq!(result["status"], "succeeded", "{result}");
    assert_eq!(result["verifiedAbsent"], true);
    assert!(!source.exists());
    assert_eq!(
        std::fs::metadata(&external).unwrap().permissions().mode() & 0o777,
        0o500
    );
    assert_eq!(
        std::fs::read_to_string(external.join("keep")).unwrap(),
        "foreign"
    );
    s.shutdown().await.unwrap();
    http.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn historical_failed_delete_replays_final_marker_without_workspace() {
    let dir = std::env::temp_dir().join(format!("neura-delete-migration-{}", uuid()));
    std::fs::create_dir(&dir).unwrap();
    let s = server::AppState::new(dir.clone(), "fixture".into(), "http://127.0.0.1:1".into())
        .await
        .unwrap();
    let (base, http) = listen(s.clone()).await;
    let op = uuid();
    let legacy = json!({"type":"workspace.delete","workspaceId":uuid(),"discardChanges":false,"stopTerminals":false});
    let hash = workspace::hash(&legacy.to_string());
    let original = json!({"code":"workspace_dirty","message":"historical failure","status":409});
    s.store
        .call("operation_start", json!({"id":op,"hash":hash}))
        .await
        .unwrap();
    s.store
        .call(
            "operation_finish",
            json!({"id":op,"status":"failed","result":original.to_string()}),
        )
        .await
        .unwrap();
    assert!(s
        .store
        .get("workspaces", legacy["workspaceId"].as_str().unwrap())
        .await
        .unwrap()
        .is_none());
    let (status, replayed) = cmd(&base, &op, legacy.clone()).await;
    assert_eq!(status, 409);
    assert_eq!(replayed["error"], original["code"]);
    assert_eq!(replayed["message"], original["message"]);
    assert_eq!(replayed["operationId"], op);
    assert_eq!(replayed["operationFinal"], true);
    let mut start = legacy.clone();
    start["type"] = json!("workspace.delete.start");
    let (_, unknown) = cmd(&base, &op, start).await;
    assert_eq!(unknown["error"], "operation_unknown");
    assert!(unknown.get("operationFinal").is_none());
    let pending = uuid();
    s.store
        .call("operation_start", json!({"id":pending,"hash":hash}))
        .await
        .unwrap();
    let (_, unknown) = cmd(&base, &pending, legacy.clone()).await;
    assert_eq!(unknown["error"], "operation_unknown");
    assert!(unknown.get("operationFinal").is_none());
    let mut changed = legacy;
    changed["discardChanges"] = json!(true);
    let (_, conflict) = cmd(&base, &op, changed).await;
    assert_eq!(conflict["error"], "operation_conflict");
    assert!(conflict.get("operationFinal").is_none());
    s.shutdown().await.unwrap();
    http.abort();
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
    // A timed-out start and its concurrent exact replay cannot later disagree.
    let rejected_op = uuid();
    server::deletion::setup_fixture(&s, w["id"].as_str().unwrap(), true).await;
    let lease = mutation::workspace_activity(w["id"].as_str().unwrap()).await;
    let mut attempts = Vec::new();
    for _ in 0..2 {
        let base = base.clone();
        let op = rejected_op.clone();
        let c = deletion(&w);
        attempts.push(tokio::spawn(async move { cmd(&base, &op, c).await }));
    }
    tokio::time::sleep(Duration::from_millis(30)).await;
    assert!(attempts.iter().all(|t| !t.is_finished()));
    drop(lease);
    for attempt in attempts {
        let (status, rejected) = attempt.await.unwrap();
        assert_eq!(status, 409);
        assert_eq!(rejected["error"], "setup_running");
        assert_eq!(rejected["operationId"], rejected_op);
        assert_eq!(rejected["operationFinal"], true);
    }
    server::deletion::setup_fixture(&s, w["id"].as_str().unwrap(), false).await;
    let (_, replayed) = cmd(&base, &rejected_op, deletion(&w)).await;
    assert_eq!(replayed["error"], "setup_running");
    assert_eq!(replayed["operationFinal"], true);
    assert!(s
        .store
        .call("workspace_deletion_get", json!({"id":rejected_op}))
        .await
        .unwrap()
        .is_null());
    let mut changed = deletion(&w);
    changed["discardChanges"] = json!(true);
    let (_, conflict) = cmd(&base, &rejected_op, changed).await;
    assert_eq!(conflict["error"], "operation_conflict");
    assert!(conflict.get("operationFinal").is_none());
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
    server::deletion::flush_diagnostics_fixture(&s).await;
    let log_path = dir.join("data/diagnostics/daemon.jsonl");
    let rows = || {
        std::fs::read_to_string(&log_path)
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str::<Value>(line).unwrap())
            .filter(|row| row["operationId"] == delete_id)
            .collect::<Vec<_>>()
    };
    assert!(rows()
        .iter()
        .any(|row| row["event"] == "operation.received"));
    assert!(!rows()
        .iter()
        .any(|row| row["event"] == "workspace.delete.admission"));
    drop(lease);
    let (status, accepted) = task.await.unwrap();
    assert_eq!(status, 200, "{accepted}");
    server::deletion::flush_diagnostics_fixture(&s).await;
    assert!(rows()
        .iter()
        .any(|row| row["event"] == "workspace.delete.admission"
            && row["durationMs"].as_f64().unwrap() >= 20.0));
    assert!(rows().iter().any(|row| row["event"] == "operation.success"));
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
    // Durable rejection survives restart and workspace disappearance; mutable
    // prechecks must not turn the old operation into a new accepted deletion.
    drop(s);
    let reopened = server::AppState::new(
        dir.join("data"),
        "fixture".into(),
        "http://127.0.0.1:1".into(),
    )
    .await
    .unwrap();
    let (replay_base, replay_http) = listen(reopened.clone()).await;
    let (_, rejected) = cmd(&replay_base, &rejected_op, deletion(&w)).await;
    assert_eq!(rejected["error"], "setup_running");
    assert_eq!(rejected["operationFinal"], true);
    assert_eq!(rejected["operationId"], rejected_op);
    reopened.shutdown().await.unwrap();
    replay_http.abort();
    drop(reopened);
    let next = dir.join("shutdown");
    std::fs::create_dir(&next).unwrap();
    let (s, p, w) = fixture(&next).await;
    let (base, http) = listen(s.clone()).await;
    let target = w["path"].as_str().unwrap();
    workspace::git(p["path"].as_str().unwrap(), &["worktree", "lock", target])
        .await
        .unwrap();
    let locked = uuid();
    let mut legacy = deletion(&w);
    legacy["type"] = json!("workspace.delete");
    for _ in 0..2 {
        let (status, failed) = cmd(&base, &locked, legacy.clone()).await;
        assert_eq!(status, 409);
        assert_eq!(failed["operationId"], locked);
        assert_eq!(failed["operationFinal"], true);
    }
    let job = finished(&base, &locked).await;
    assert_eq!(job["status"], "failed");
    assert_eq!(job["blocksWorkspace"], false);
    assert!(Path::new(target).join("file").exists());
    workspace::git(p["path"].as_str().unwrap(), &["worktree", "unlock", target])
        .await
        .unwrap();
    let retryop = uuid();
    let (entered, _release) =
        server::deletion::pause_fixture(&s, &format!("{locked}:remove-files")).await;
    assert_eq!(
        cmd(
            &base,
            &retryop,
            json!({"type":"workspace.deletion.retry","jobId":locked})
        )
        .await
        .0,
        200
    );
    tokio::time::timeout(Duration::from_secs(10), entered.notified())
        .await
        .unwrap();
    assert_eq!(get(&base, &locked).await["phase"], "remove-files");
    s.shutdown().await.unwrap();
    http.abort();
    drop(s);
    // Reopen the persisted profile (normal shutdown after isolation). Recovery
    // must continue, not re-apply clean checks to a partly removed worktree.
    let restarted = server::AppState::new(
        next.join("data"),
        "fixture".into(),
        "http://127.0.0.1:1".into(),
    )
    .await
    .unwrap();
    let (base, http) = listen(restarted.clone()).await;
    assert_eq!(finished(&base, &locked).await["status"], "succeeded");
    restarted.shutdown().await.unwrap();
    http.abort();
    // Reuse this test process's supervisor profile: it is intentionally a
    // singleton, so independent API fixtures must not initialize a second one.
    approved_read_only_directories_are_removed_without_changing_external_targets().await;
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
        "target-replacement",
        "wrong-project",
        "metadata-replacement",
        "move-exit-error",
        "move-timeout",
        "move-partial",
        "remove-exit-error",
        "move-no-effect",
        "move-replaced",
    ] {
        let temp = std::env::temp_dir().join(format!("neura-delete-crash-{}", uuid()));
        std::fs::create_dir(&temp).unwrap();
        let dir = std::fs::canonicalize(temp).unwrap();
        std::fs::create_dir(dir.join("data")).unwrap();
        let id = uuid();
        let corrupt = [
            "replacement",
            "symlink",
            "target-replacement",
            "wrong-project",
            "metadata-replacement",
        ]
        .contains(&window);
        let git_fault = window.starts_with("move-") || window == "remove-exit-error";
        let seed = if git_fault {
            "before-move"
        } else if corrupt {
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
        if window == "target-replacement" {
            std::fs::rename(&target, &kept).unwrap();
            std::fs::create_dir(&target).unwrap();
            std::fs::write(target.join("keep"), "foreign").unwrap();
        }
        if window == "wrong-project" {
            std::fs::rename(dir.join("repo"), &kept).unwrap();
            std::fs::create_dir(dir.join("repo")).unwrap();
            std::fs::create_dir(dir.join("repo/.git")).unwrap();
            std::fs::write(dir.join("repo/keep"), "foreign").unwrap();
        }
        if window == "metadata-replacement" {
            let db = rusqlite::Connection::open(dir.join("data/developer.sqlite")).unwrap();
            let data: String = db
                .query_row(
                    "SELECT data FROM workspace_deletions WHERE id=?",
                    [&id],
                    |r| r.get(0),
                )
                .unwrap();
            let record: Value = serde_json::from_str(&data).unwrap();
            let admin = Path::new(record["fence"]["admin"].as_str().unwrap());
            std::fs::rename(admin, &kept).unwrap();
            std::fs::create_dir(admin).unwrap();
            std::fs::write(admin.join("keep"), "foreign").unwrap();
        }
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        drop(listener);
        std::fs::write(dir.join("data/daemon-token"), "fixture").unwrap();
        let mut command = tokio::process::Command::new(binary());
        if git_fault {
            use std::os::unix::fs::PermissionsExt;
            let bin = dir.join("bin");
            std::fs::create_dir(&bin).unwrap();
            // Exercise the real subprocess runner, not a mocked Result. Git
            // completes its side effect and is reaped with a failing status.
            std::fs::write(
                bin.join("git"),
                r#"#!/bin/sh
previous=''
before=''
step=''
for arg in "$@"; do
    if [ "$previous" = worktree ]; then step="$arg"; fi
    before="$previous"
    previous="$arg"
done
if [ "$step" = move ] && [ "$NEURA_GIT_FAULT" = move-no-effect ]; then exit 1; fi
if [ "$step" = move ] && [ "$NEURA_GIT_FAULT" = move-partial ]; then
    /bin/mv "$before" "$previous" || exit 2
    exit 1
fi
/usr/bin/git "$@" || exit $?
if [ "$step" = move ] && [ "$NEURA_GIT_FAULT" = move-timeout ]; then /bin/sleep 60; fi
if [ "$step" = move ] && [ "$NEURA_GIT_FAULT" = move-replaced ]; then
    /bin/mv "$previous" "$previous-kept" || exit 2
    /bin/mkdir "$previous" || exit 2
    echo foreign > "$previous/keep"
    exit 1
fi
if [ "$step-exit-error" = "$NEURA_GIT_FAULT" ]; then exit 1; fi
exit 0
"#,
            )
            .unwrap();
            std::fs::set_permissions(bin.join("git"), std::fs::Permissions::from_mode(0o700))
                .unwrap();
            command.env(
                "PATH",
                format!("{}:/usr/bin:/bin:/usr/sbin:/sbin", bin.display()),
            );
            command.env("NEURA_GIT_FAULT", window);
        }
        let mut daemon = command
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
        if corrupt {
            assert_eq!(result["status"], "failed", "{window}: {result}");
            assert_eq!(result["blocksWorkspace"], true);
            assert_eq!(result["retryable"], false);
            assert_eq!(result["error"]["code"], "deletion_identity_changed");
            let preserved = match window {
                "replacement" => source.join("keep"),
                "target-replacement" => target.join("keep"),
                "wrong-project" => dir.join("repo/keep"),
                "metadata-replacement" => {
                    let db = rusqlite::Connection::open(dir.join("data/developer.sqlite")).unwrap();
                    let data: String = db
                        .query_row(
                            "SELECT data FROM workspace_deletions WHERE id=?",
                            [&id],
                            |r| r.get(0),
                        )
                        .unwrap();
                    let record: Value = serde_json::from_str(&data).unwrap();
                    PathBuf::from(record["fence"]["admin"].as_str().unwrap()).join("keep")
                }
                _ => kept.join("keep"),
            };
            assert_eq!(std::fs::read_to_string(preserved).unwrap(), "foreign");
        } else if window == "move-no-effect" || window == "move-replaced" {
            assert_eq!(result["status"], "failed", "{window}: {result}");
            assert_ne!(result["verifiedAbsent"], true);
            if window == "move-no-effect" {
                assert_eq!(result["error"]["code"], "git_failed");
                assert_eq!(result["blocksWorkspace"], false);
                assert_eq!(
                    std::fs::read_to_string(source.join("file")).unwrap(),
                    "original"
                );
            } else {
                assert_eq!(result["error"]["code"], "deletion_identity_changed");
                assert_eq!(result["retryable"], false);
                assert_eq!(result["blocksWorkspace"], true);
                assert_eq!(
                    std::fs::read_to_string(target.join("keep")).unwrap(),
                    "foreign\n"
                );
                assert_eq!(
                    std::fs::read_to_string(dir.join(format!(".neura-delete-{id}-kept/file")))
                        .unwrap(),
                    "original"
                );
            }
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
