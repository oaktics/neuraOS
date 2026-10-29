use neura_native_core::{github::run_git, process_tree};
use std::{path::Path, time::Duration};

#[tokio::test]
async fn git_leader_exit_stops_descendants_before_waiting_for_pipe_eof() {
    let dir = std::env::temp_dir().join(format!("neura-git-eof-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir(&dir).unwrap();
    eprintln!("Git process fixture: {}", dir.display());
    process_tree::ensure_supervisor(
        Path::new(env!("CARGO_BIN_EXE_neura-native-core")),
        &dir.join("supervisor.lock"),
    ).await.unwrap();
    for code in [0, 7, 0, 7] {
        // Like a pre-push hook: the leader exits while its background child
        // holds the inherited output pipes open. No network or real repo.
        let alias = format!("alias.fixture=!sleep 120 & echo $! > child.pid; printf ready; exit {code}");
        let result = tokio::time::timeout(Duration::from_secs(5), run_git(
            dir.to_string_lossy().into_owned(), vec!["-c".into(), alias, "fixture".into()],
        )).await;
        let pid: i32 = std::fs::read_to_string(dir.join("child.pid")).unwrap().trim().parse().unwrap();
        tokio::time::timeout(Duration::from_secs(5), async {
            while unsafe { libc::kill(pid, 0) } == 0 {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        }).await.unwrap_or_else(|_| panic!("owned pipe holder {pid} must stop; fixture {}", dir.display()));
        let result = result.expect("leader completion must not wait for inherited pipe EOF");
        if code == 0 { assert_eq!(result.unwrap(), "ready"); }
        else { assert_eq!(result.unwrap_err().error, "git_failed"); }
    }
    let cwd = dir.to_string_lossy().into_owned();
    let work = tokio::spawn(run_git(cwd, vec![
        "-c".into(),
        "alias.fixture=!sleep 120 & echo $! > cancel.pid; sleep 120".into(),
        "fixture".into(),
    ]));
    tokio::time::timeout(Duration::from_secs(5), async {
        while !dir.join("cancel.pid").exists() {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }).await.unwrap();
    let pid: i32 = std::fs::read_to_string(dir.join("cancel.pid")).unwrap().trim().parse().unwrap();
    work.abort();
    assert!(work.await.unwrap_err().is_cancelled());
    tokio::time::timeout(Duration::from_secs(5), async {
        while unsafe { libc::kill(pid, 0) } == 0 {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }).await.expect("cancelled git call must stop descendants before reaping leader");
    // Keep the helper's lifetime lock inode until this test runtime exits.
}
