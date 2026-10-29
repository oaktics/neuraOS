//! Real restricted /bin/sleep orphan; no model CLI or production profile.
use neura_native_core::process_tree::{self, OwnedChild};
use std::{path::Path, process::Stdio, time::Duration};
use tokio::io::AsyncReadExt;

#[tokio::test]
async fn unreaped_git_leader_anchors_restricted_orphan_and_cancel_reaps() {
    let dir = std::env::temp_dir().join(format!("neura-exit-anchor-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir(&dir).unwrap();
    process_tree::ensure_supervisor(
        Path::new(env!("CARGO_BIN_EXE_neura-native-core")),
        &dir.join("supervisor.lock"),
    )
    .await
    .unwrap();
    for (index, code) in [0, 7, 0, 7, 0, 7, 0, 7].into_iter().enumerate() {
        let lease = process_tree::reserve().await.unwrap();
        let alias =
            format!("alias.fixture=!sleep 120 & echo $! > child.pid; printf ready; exit {code}");
        let child = tokio::process::Command::new("/usr/bin/git")
            .args(["-c", &alias, "fixture"])
            .current_dir(&dir)
            .env(process_tree::OWNER_ENV, lease.token())
            .process_group(0)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .spawn()
            .unwrap();
        let mut child = OwnedChild::new(child, lease.clone());
        let pid = child.child_mut().id().unwrap();
        // Deterministically force the formerly blind window: the restricted
        // descendant is orphaned and leader zombie before monitor attachment.
        let waited = tokio::task::spawn_blocking(move || unsafe {
            let mut status: libc::siginfo_t = std::mem::zeroed();
            libc::waitid(libc::P_PID, pid, &mut status, libc::WEXITED | libc::WNOWAIT)
        })
        .await
        .unwrap();
        assert_eq!(waited, 0);
        if index % 4 != 3 {
            lease.attach(pid).await.unwrap();
            tokio::time::timeout(Duration::from_secs(3), lease.wait_exit())
                .await
                .unwrap()
                .unwrap();
        }
        let orphan: i32 = std::fs::read_to_string(dir.join("child.pid"))
            .unwrap()
            .trim()
            .parse()
            .unwrap();
        assert_eq!(
            unsafe { libc::kill(pid as i32, 0) },
            0,
            "leader must remain unreaped"
        );
        if index % 4 < 2 {
            let mut out = child.child_mut().stdout.take().unwrap();
            lease.stop().await.unwrap();
            let status = child.child_mut().wait().await.unwrap();
            assert_eq!(status.code(), Some(code));
            let mut bytes = Vec::new();
            tokio::time::timeout(Duration::from_secs(2), out.read_to_end(&mut bytes))
                .await
                .unwrap()
                .unwrap();
            assert_eq!(bytes, b"ready");
            let _ = child.into_inner();
        } else {
            // Same path as cancellation after wait_exit but before cleanup.
            drop(child);
        }
        tokio::time::timeout(Duration::from_secs(5), async {
            while unsafe { libc::kill(orphan, 0) } == 0 || unsafe { libc::kill(pid as i32, 0) } == 0
            {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("restricted orphan and unreaped leader must both disappear");
    }
}
