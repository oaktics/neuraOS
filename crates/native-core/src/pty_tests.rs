use crate::{events::Change, pty::PtyRuntime, store::StoreHandle};
use serde_json::json;
use std::{
    collections::{HashMap, HashSet},
    time::Duration,
};
use tokio::sync::broadcast;

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn concurrent_native_ptys_drain_utf8_and_replay_after_shutdown() {
    let directory =
        std::env::temp_dir().join(format!("neura-native-pty-test-{}", uuid::Uuid::new_v4()));
    tokio::fs::create_dir(&directory).await.unwrap();
    let database = directory.join("state.sqlite");
    let (events, _) = broadcast::channel::<Change>(1024);
    let store = StoreHandle::open(&database, events.clone()).await.unwrap();
    let pty = PtyRuntime::new(store.clone()).unwrap();
    let mut exits = pty.subscribe_exit();
    let count = 32;
    let rows = 128;
    let mut ids = Vec::new();
    let mut expected = HashMap::new();
    let program=format!("import sys,termios\nattrs=termios.tcgetattr(1)\nattrs[1] &= ~termios.OPOST\ntermios.tcsetattr(1,termios.TCSANOW,attrs)\nidentity=sys.argv[1]\nfor i in range({rows}):\n sys.stdout.write('ROW:'+identity+':'+str(i)+':'+'x'*2048+':日本語:END\\n')\n sys.stdout.flush()\n");
    for index in 0..count {
        let id = uuid::Uuid::new_v4().to_string();
        store.put("terminals",json!({"id":id,"workspaceId":"fixture","provider":"shell","status":"running","cols":100,"rows":30,"createdAt":""}),None).await.unwrap();
        pty.spawn(
            &id,
            "/usr/bin/python3",
            vec!["-c".into(), program.clone(), index.to_string()],
            directory.to_str().unwrap(),
            HashMap::from([
                ("PATH".into(), "/usr/bin:/bin".into()),
                ("LANG".into(), "en_US.UTF-8".into()),
            ]),
        )
        .await
        .unwrap();
        ids.push(id);
    }
    let result = tokio::time::timeout(Duration::from_secs(30), async {
        let mut completed = HashSet::new();
        while completed.len() < count {
            let exit = exits.recv().await.unwrap();
            assert_eq!(exit.exit_code, 0);
            completed.insert(exit.terminal_id);
        }
        for (index, id) in ids.iter().enumerate() {
            let text = read(&store, id).await;
            let lines: Vec<_> = text
                .lines()
                .filter(|line| line.starts_with("ROW:"))
                .collect();
            assert_eq!(lines.len(), rows, "row count for terminal {index}");
            for (row, line) in lines.into_iter().enumerate() {
                assert_eq!(
                    line,
                    format!("ROW:{index}:{row}:{}:日本語:END", "x".repeat(2048))
                );
            }
            assert_eq!(
                store.get("terminals", id).await.unwrap().unwrap()["status"],
                "exited"
            );
            expected.insert(id.clone(), text);
        }
    })
    .await;
    pty.shutdown().await.unwrap();
    assert!(
        result.is_ok(),
        "native PTYs stalled before EOF: {} of {} still running",
        ids.iter().filter(|id| pty.pid(id).is_some()).count(),
        count
    );
    drop(pty);
    drop(store);
    let reopened = StoreHandle::open(&database, events).await.unwrap();
    for id in ids {
        assert_eq!(
            read(&reopened, &id).await,
            expected[&id],
            "durable replay differs"
        );
    }
    drop(reopened);
    tokio::fs::remove_dir_all(directory).await.unwrap();
}
async fn read(store: &StoreHandle, id: &str) -> String {
    let mut cursor = 0;
    let mut text = String::new();
    loop {
        let v = store
            .call("output", json!({"terminalId":id,"after":cursor}))
            .await
            .unwrap();
        text.push_str(v["data"].as_str().unwrap());
        let next = v["cursor"].as_i64().unwrap();
        assert!(next >= cursor);
        cursor = next;
        if v["more"] != true {
            return text;
        }
    }
}

#[tokio::test]
async fn failed_output_commit_wakes_clients_and_never_acknowledges_input_as_healthy() {
    let directory = std::env::temp_dir().join(format!("neura-pty-fault-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir(&directory).unwrap();
    let (events, mut changes) = broadcast::channel::<Change>(32);
    let store = StoreHandle::open(&directory.join("state.sqlite"), events)
        .await
        .unwrap();
    store.call("transaction", json!([{"sql":"CREATE TRIGGER reject_output BEFORE INSERT ON output BEGIN SELECT RAISE(ABORT,'fixture storage fault'); END","args":[]}])).await.unwrap();
    let id = uuid::Uuid::new_v4().to_string();
    store
        .put("terminals", json!({"id":id,"status":"running"}), None)
        .await
        .unwrap();
    while changes.try_recv().is_ok() {}
    let pty = PtyRuntime::new(store.clone()).unwrap();
    // Shell builtins avoid measuring Python startup under concurrent CI PTY load.
    // The side-channel marker separates producer progress from durable-write/fault notification.
    // read keeps the leader alive without spawning sleep or other descendants.
    let emitted = directory.join("emitted");
    let mut env = HashMap::new();
    env.insert(
        "FAULT_EMITTED".into(),
        emitted.to_string_lossy().into_owned(),
    );
    let pid = pty
        .spawn(
            &id,
            "/bin/sh",
            vec![
                "-c".into(),
                "printf 'uncommitted\\n'; : > \"$FAULT_EMITTED\"; read -r hold".into(),
            ],
            "/tmp",
            env,
        )
        .await
        .unwrap();
    let producer = tokio::time::timeout(Duration::from_secs(5), async {
        while !emitted.exists() {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await;
    let notification = tokio::time::timeout(Duration::from_secs(5), changes.recv()).await;
    let healthy = pty.check_healthy().is_ok();
    let input = pty.input(&id, "must not acknowledge").await;
    let output = store
        .call("output", json!({"terminalId":id,"after":0}))
        .await
        .unwrap();
    // Always stop/reap before assertions, including a failed producer/notification deadline.
    let shutdown = pty.shutdown().await;
    let reaped = tokio::time::timeout(Duration::from_secs(5), async {
        while unsafe { libc::kill(pid as i32, 0) } == 0 {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await;
    drop(pty);
    drop(store);
    let _ = std::fs::remove_dir_all(directory);
    assert!(producer.is_ok(), "shell producer did not confirm PTY write");
    assert!(
        notification.is_ok(),
        "producer wrote, but storage-fault notification missing; healthy={healthy}"
    );
    assert!(notification.unwrap().unwrap().state);
    assert!(!healthy);
    assert_eq!(input.unwrap_err().error, "terminal_runtime_failed");
    assert_eq!(output["data"], "");
    assert!(shutdown.is_err());
    assert!(reaped.is_ok(), "faulted PTY leader was not reaped");
}
