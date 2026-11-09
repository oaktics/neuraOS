//! Isolated native PTYs only: never opens a model CLI or a user's worktree.
use neura_native_core::{
    browser, contracts, diagnostics, error, events, github, mutation, process_tree, providers, pty,
    store, usage, workspace,
};
// server belongs to the binary; compile the exact production module for this fixture.
#[path = "../src/server.rs"]
#[allow(dead_code)]
mod server;
use serde_json::json;
use server::AppState;
use std::{collections::HashMap, path::Path, time::Duration};

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn workspace_stop_overlaps_grace_periods_and_preserves_other_workspaces() {
    let dir = std::env::temp_dir().join(format!("neura-workspace-stop-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir(&dir).unwrap();
    process_tree::ensure_supervisor(
        Path::new(env!("CARGO_BIN_EXE_neura-native-core")),
        &dir.join("owner.lock"),
    )
    .await
    .unwrap();
    let state = AppState::new(dir.clone(), "fixture".into(), "http://127.0.0.1:1".into())
        .await
        .unwrap();
    let mut terminals = Vec::new();
    let mut pids = Vec::new();
    for index in 0..5 {
        let id = uuid::Uuid::new_v4().to_string();
        let workspace = if index == 4 { "other" } else { "target" };
        state.store.put("terminals", json!({"id":id,"workspaceId":workspace,"provider":"shell","status":"running","cols":100,"rows":30}), None).await.unwrap();
        let marker = dir.join(format!("ready-{index}"));
        // Both leader and restricted child ignore TERM, forcing real escalation.
        let script = format!(
            "trap '' TERM HUP; /bin/sleep 60 & printf '%s %s' $$ $! > '{}'; wait",
            marker.display()
        );
        state
            .pty
            .spawn(
                &id,
                "/bin/sh",
                vec!["-c".into(), script],
                dir.to_str().unwrap(),
                HashMap::from([("PATH".into(), "/usr/bin:/bin".into())]),
            )
            .await
            .unwrap();
        tokio::time::timeout(Duration::from_secs(10), async {
            loop {
                if let Ok(record) = std::fs::read_to_string(&marker) {
                    let found: Vec<i32> = record
                        .split_whitespace()
                        .filter_map(|v| v.parse().ok())
                        .collect();
                    if found.len() == 2 {
                        pids.push(found);
                        break;
                    }
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        terminals.push(id);
    }
    let started = std::time::Instant::now();
    let stopped = state.stop_workspace("target").await;
    let elapsed = started.elapsed();
    eprintln!("workspace_stop: 4 TERM-resistant PTYs + children: {elapsed:?}");
    let statuses = state.store.list("terminals").await.unwrap();
    let other_alive = pids[4]
        .iter()
        .all(|pid| unsafe { libc::kill(*pid, 0) } == 0);
    // Observe real disappearance, including launchd reaping of orphan children.
    let gone = tokio::time::timeout(Duration::from_secs(3), async {
        while pids[..4]
            .iter()
            .flatten()
            .any(|pid| unsafe { libc::kill(*pid, 0) } == 0)
        {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await;
    // Clean up the fixture even if a regression assertion below fails.
    state.shutdown().await.unwrap();
    stopped.unwrap();
    assert!(gone.is_ok(), "owned leader or child survived stop");
    assert!(other_alive, "another workspace was stopped");
    for id in &terminals[..4] {
        assert_ne!(
            statuses.iter().find(|row| row["id"] == *id).unwrap()["status"],
            "running"
        );
    }
    assert_eq!(
        statuses
            .iter()
            .find(|row| row["id"] == terminals[4])
            .unwrap()["status"],
        "running"
    );
    assert!(
        elapsed < Duration::from_secs(4),
        "grace periods were serialized: {elapsed:?}"
    );
    deletion_guards_and_diagnostics(&dir).await;
    failed_close_still_drains_other_terminals(&dir).await;
    // Retain the supervisor lifetime-lock inode until runtime teardown.
}

async fn deletion_guards_and_diagnostics(dir: &Path) {
    let data = dir.join("delete-data");
    std::fs::create_dir(&data).unwrap();
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
    let state = AppState::new(data.clone(), "fixture".into(), "http://127.0.0.1:1".into())
        .await
        .unwrap();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let endpoint = format!("http://{}/v1/commands", listener.local_addr().unwrap());
    let router = server::router(state.clone());
    let http = tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    let command = |command: serde_json::Value| {
        let endpoint = endpoint.clone();
        async move {
            let operation = uuid::Uuid::new_v4().to_string();
            let response = reqwest::Client::new()
                .post(endpoint)
                .bearer_auth("fixture")
                .json(&json!({"operationId":operation,"command":command}))
                .send()
                .await
                .unwrap();
            let status = response.status().as_u16();
            let body = response.json::<serde_json::Value>().await.unwrap();
            (status, body, operation)
        }
    };
    let (status, project, _) = command(json!({"type":"project.add","path":root})).await;
    assert_eq!(status, 200, "{project}");
    let (status, worktree, _) = command(json!({"type":"workspace.create","projectId":project["id"],"baseRef":"HEAD","skipStartup":true})).await;
    assert_eq!(status, 200, "{worktree}");
    let target = Path::new(worktree["path"].as_str().unwrap());
    let delete =
        json!({"type":"workspace.delete","workspaceId":worktree["id"],"stopTerminals":true});
    std::fs::write(target.join("file"), "dirty").unwrap();
    let (status, error, failed_op) = command(delete.clone()).await;
    assert_eq!(status, 409);
    assert_eq!(error["error"], "workspace_dirty");
    assert!(target.exists());
    workspace::git(target.to_str().unwrap(), &["restore", "file"])
        .await
        .unwrap();
    std::fs::create_dir(target.join("ignored")).unwrap();
    std::fs::write(target.join("ignored/secret"), "fixture-secret").unwrap();
    let (_, error, _) = command(delete.clone()).await;
    assert_eq!(error["error"], "workspace_ignored_files");
    assert!(target.join("ignored/secret").exists());
    std::fs::remove_dir_all(target.join("ignored")).unwrap();

    // A process writing during shutdown must still fail the second verification.
    let terminal = uuid::Uuid::new_v4().to_string();
    state.store.put("terminals", json!({"id":terminal,"workspaceId":worktree["id"],"provider":"shell","status":"running","cols":80,"rows":24}), None).await.unwrap();
    let marker = dir.join("trap-ready");
    let script = format!("trap 'printf changed > file; exit 0' TERM; printf ready > '{}'; while :; do /bin/sleep 1; done", marker.display());
    state
        .pty
        .spawn(
            &terminal,
            "/bin/sh",
            vec!["-c".into(), script],
            target.to_str().unwrap(),
            HashMap::new(),
        )
        .await
        .unwrap();
    tokio::time::timeout(Duration::from_secs(5), async {
        while !marker.exists() {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
    let (_, error, after_op) = command(delete.clone()).await;
    assert_eq!(error["error"], "workspace_dirty", "{error}");
    assert!(target.exists());
    assert_eq!(
        std::fs::read_to_string(target.join("file")).unwrap(),
        "changed"
    );
    workspace::git(target.to_str().unwrap(), &["restore", "file"])
        .await
        .unwrap();
    let (status, body, success_op) = command(delete).await;
    assert_eq!(status, 200, "{body}");
    assert!(!target.exists());
    assert!(state
        .store
        .get("workspaces", worktree["id"].as_str().unwrap())
        .await
        .unwrap()
        .is_none());

    // A wakeup is never evidence of exit. Missing owner + stale running row
    // must wait for durable state and still time out when it never arrives.
    let stale = uuid::Uuid::new_v4().to_string();
    state
        .store
        .put(
            "terminals",
            json!({"id":stale,"workspaceId":"stale","provider":"shell","status":"running"}),
            None,
        )
        .await
        .unwrap();
    let wait = state.stop_workspace("stale");
    let update = async {
        tokio::time::sleep(Duration::from_millis(50)).await;
        state
            .store
            .update("terminals", &stale, |row| row["status"] = json!("exited"))
            .await
            .unwrap();
    };
    let (result, ()) = tokio::join!(wait, update);
    result.unwrap();
    state
        .store
        .update("terminals", &stale, |row| row["status"] = json!("running"))
        .await
        .unwrap();
    assert_eq!(
        state.stop_workspace("stale").await.unwrap_err().error,
        "terminal_stop_timeout"
    );
    state
        .store
        .update("terminals", &stale, |row| row["status"] = json!("exited"))
        .await
        .unwrap();
    state.shutdown().await.unwrap();
    http.abort();
    let log = std::fs::read_to_string(data.join("diagnostics/daemon.jsonl")).unwrap();
    assert!(!log.contains(root));
    assert!(!log.contains("fixture-secret"));
    assert!(!log.contains("workspace_dirty"));
    let rows: Vec<serde_json::Value> = log
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    let phases = |operation: &str| {
        rows.iter()
            .filter(|row| {
                row["operationId"] == operation
                    && row["event"]
                        .as_str()
                        .unwrap()
                        .starts_with("workspace.delete.")
            })
            .map(|row| {
                assert!(row["durationMs"].as_f64().unwrap() >= 0.0);
                row["event"].as_str().unwrap()
            })
            .collect::<Vec<_>>()
    };
    assert_eq!(phases(&failed_op), vec!["workspace.delete.verify-before"]);
    assert_eq!(
        phases(&after_op),
        vec![
            "workspace.delete.verify-before",
            "workspace.delete.stop-terminals",
            "workspace.delete.verify-after"
        ]
    );
    assert_eq!(
        phases(&success_op),
        vec![
            "workspace.delete.verify-before",
            "workspace.delete.stop-terminals",
            "workspace.delete.verify-after",
            "workspace.delete.git-remove",
            "workspace.delete.forget-agents",
            "workspace.delete.store"
        ]
    );
}

async fn failed_close_still_drains_other_terminals(dir: &Path) {
    let data = dir.join("failure-data");
    std::fs::create_dir(&data).unwrap();
    let state = AppState::new(data, "fixture".into(), "http://127.0.0.1:1".into())
        .await
        .unwrap();
    let bad = uuid::Uuid::new_v4().to_string();
    let good = uuid::Uuid::new_v4().to_string();
    for id in [&bad, &good] {
        state.store.put("terminals", json!({"id":id,"workspaceId":"failure","provider":"shell","status":"running","cols":80,"rows":24}), None).await.unwrap();
    }
    // No CLI: only a synthetic persisted agent whose close write will fail.
    state
        .providers
        .agents
        .prepare_claude(
            json!({"id":"failure","path":dir,"name":"fixture"}),
            &bad,
            None,
            None,
            None,
        )
        .await
        .unwrap();
    state.providers.agents.claude_event(&bad, &json!({"hook_event_name":"SessionStart","session_id":uuid::Uuid::new_v4().to_string()})).await.unwrap();
    state.store.call("transaction", json!([{"sql":"CREATE TRIGGER reject_close BEFORE INSERT ON agents BEGIN SELECT RAISE(ABORT,'fixture close failure'); END","args":[]}])).await.unwrap();
    let marker = dir.join("failure-ready");
    state
        .pty
        .spawn(
            &good,
            "/bin/sh",
            vec![
                "-c".into(),
                format!(
                    "trap '' TERM HUP; printf ready > '{}'; /bin/sleep 60 & wait",
                    marker.display()
                ),
            ],
            dir.to_str().unwrap(),
            HashMap::new(),
        )
        .await
        .unwrap();
    tokio::time::timeout(Duration::from_secs(5), async {
        while !marker.exists() {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
    let pid = state.pty.pid(&good).unwrap();
    let result = state.stop_workspace("failure").await;
    let gone = tokio::time::timeout(Duration::from_secs(3), async {
        while unsafe { libc::kill(pid as i32, 0) } == 0 {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await;
    state
        .store
        .call(
            "transaction",
            json!([{"sql":"DROP TRIGGER reject_close","args":[]}]),
        )
        .await
        .unwrap();
    // Provider close failures remain sticky and cannot be reported as success.
    let shutdown = state.shutdown().await;
    assert!(result.is_err());
    assert!(shutdown.is_err());
    assert!(
        gone.is_ok(),
        "failed sibling close cancelled the remaining owner stop"
    );
}
