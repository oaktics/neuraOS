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
async fn failed_output_commit_wakes_clients_and_never_acknowledges_input_as_healthy(){
 let directory=std::env::temp_dir().join(format!("neura-pty-fault-{}",uuid::Uuid::new_v4()));std::fs::create_dir(&directory).unwrap();
 let(events,mut changes)=broadcast::channel::<Change>(32);let store=StoreHandle::open(&directory.join("state.sqlite"),events).await.unwrap();
 store.call("transaction",json!([{"sql":"CREATE TRIGGER reject_output BEFORE INSERT ON output BEGIN SELECT RAISE(ABORT,'fixture storage fault'); END","args":[]}])).await.unwrap();
 let id=uuid::Uuid::new_v4().to_string();store.put("terminals",json!({"id":id,"status":"running"}),None).await.unwrap();while changes.try_recv().is_ok(){}
 let pty=PtyRuntime::new(store.clone()).unwrap();let pid=pty.spawn(&id,"/usr/bin/python3",vec!["-c".into(),"import sys,time;print('uncommitted');sys.stdout.flush();time.sleep(30)".into()],"/tmp",HashMap::new()).await.unwrap();
 let event=tokio::time::timeout(Duration::from_secs(5),changes.recv()).await.unwrap().unwrap();assert!(event.state);assert!(pty.check_healthy().is_err());assert_eq!(pty.input(&id,"must not acknowledge").await.unwrap_err().error,"terminal_runtime_failed");
 assert_eq!(store.call("output",json!({"terminalId":id,"after":0})).await.unwrap()["data"],"");assert!(pty.shutdown().await.is_err());
 tokio::time::timeout(Duration::from_secs(5),async{while unsafe{libc::kill(pid as i32,0)}==0{tokio::time::sleep(Duration::from_millis(10)).await;}}).await.unwrap();drop(pty);drop(store);let _=std::fs::remove_dir_all(directory);
}
