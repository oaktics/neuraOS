//! Uses the built native daemon as the helper, never the Rust test harness.
//! Optional real protocol smoke: NEURA_TEST_CODEX_PATH=/path/to/codex cargo test
//! --test provider_process. No prompt/turn or model API request is submitted.
use neura_native_core::{
    process_tree,
    providers::{codex::CodexRpc, event_queue},
};
use std::{collections::HashMap, os::unix::fs::PermissionsExt, path::PathBuf, time::Duration};

#[tokio::test]
async fn direct_codex_startup_cancellation_and_optional_real_connection() {
    let profile = std::env::temp_dir().join(format!(
        "neura-codex-native-fixture-{}",
        uuid::Uuid::new_v4()
    ));
    std::fs::create_dir(&profile).unwrap();
    process_tree::ensure_supervisor(
        std::path::Path::new(env!("CARGO_BIN_EXE_neura-native-core")),
        &profile.join("owner.lock"),
    )
    .await
    .unwrap();
    let marker = profile.join("started");
    let program = profile.join("codex-fixture");
    std::fs::write(&program,b"#!/bin/sh\ntrap '' TERM HUP\nprintf '%s\\n%s\\n' \"$$\" \"$3\" > \"$NEURA_FIXTURE_MARKER\"\nsleep 30 &\nwait\n").unwrap();
    std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o700)).unwrap();
    let mut env = HashMap::new();
    env.insert("NEURA_FIXTURE_MARKER".into(), marker.display().to_string());
    let (events, _rx) = event_queue::channel();
    let start =
        tokio::spawn(
            async move { CodexRpc::start(program.to_str().unwrap(), &env, &[], events).await },
        );
    tokio::time::timeout(Duration::from_secs(5), async {
        while !marker.exists() {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
    let record = std::fs::read_to_string(&marker).unwrap();
    let mut lines = record.lines();
    let pid: i32 = lines.next().unwrap().parse().unwrap();
    let socket = PathBuf::from(lines.next().unwrap().strip_prefix("unix://").unwrap());
    assert!(socket.as_os_str().len() < 104);
    let directory = socket.parent().unwrap().to_owned();
    start.abort();
    let _ = start.await;
    tokio::time::timeout(Duration::from_secs(6), async {
        while directory.exists() || unsafe { libc::kill(pid, 0) } == 0 {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .unwrap();
    if let Some(program) = std::env::var_os("NEURA_TEST_CODEX_PATH") {
        let home = profile.join("codex-home");
        std::fs::create_dir(&home).unwrap();
        let env = HashMap::from([
            ("CODEX_HOME".into(), home.display().to_string()),
            ("OPENAI_API_KEY".into(), String::new()),
        ]);
        let (events, _rx) = event_queue::channel();
        let rpc = CodexRpc::start(program.to_str().unwrap(), &env, &[], events)
            .await
            .unwrap();
        let pid = rpc.pid;
        let loaded = rpc
            .call("thread/loaded/list", serde_json::json!({}))
            .await
            .unwrap();
        assert!(loaded["data"].is_array());
        rpc.close().await.unwrap();
        assert_eq!(unsafe { libc::kill(pid as i32, 0) }, -1);
    }
    // Keep this isolated profile's lifetime lock inode until the helper exits
    // when the test runtime drops its pipe; never unlink an active lock file.
}
