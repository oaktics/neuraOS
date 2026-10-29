use neura_native_core::{process_tree, workspace};
#[tokio::test]
async fn bounded_native_runner_reaps_children_on_limit_timeout_and_cancel() {
    let dir = std::env::temp_dir().join(format!("neura-runner-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir(&dir).unwrap();
    process_tree::ensure_supervisor(
        std::path::Path::new(env!("CARGO_BIN_EXE_neura-native-core")),
        &dir.join("owner.lock"),
    )
    .await
    .unwrap();
    for script in [
        "import sys;sys.stdout.write('x'*5000000)",
        "import sys;sys.stderr.write('x'*100000)",
    ] {
        let e = workspace::run("/tmp", "/usr/bin/python3", &["-c", script], 5)
            .await
            .unwrap_err();
        assert_eq!(e.error, "output_too_large");
    }
    assert_eq!(
        workspace::run(
            "/tmp",
            "/usr/bin/python3",
            &["-c", "import sys;sys.stderr.write('x'*50000);print('ok')"],
            5
        )
        .await
        .unwrap(),
        "ok\n"
    );
    let pidfile = dir.join("child.pid");
    let source=format!("import os,time\npid=os.fork()\nif pid==0:\n os.setsid()\n open({:?},'w').write(str(os.getpid()))\n time.sleep(60)\nelse:\n time.sleep(60)\n",pidfile.to_string_lossy());
    let error = workspace::run("/tmp", "/usr/bin/python3", &["-c", &source], 1)
        .await
        .unwrap_err();
    assert_eq!(error.error, "operation_timeout");
    let pid = std::fs::read_to_string(&pidfile)
        .unwrap()
        .parse::<i32>()
        .unwrap();
    assert_eq!(unsafe { libc::kill(pid, 0) }, -1);
    assert_eq!(
        std::io::Error::last_os_error().raw_os_error(),
        Some(libc::ESRCH)
    );
    let cancel_pid = dir.join("cancel.pid");
    let source = format!(
        "import os,time\nopen({:?},'w').write(str(os.getpid()))\ntime.sleep(60)\n",
        cancel_pid.to_string_lossy()
    );
    let task = tokio::spawn(async move {
        workspace::run("/tmp", "/usr/bin/python3", &["-c", &source], 30).await
    });
    tokio::time::timeout(std::time::Duration::from_secs(5), async {
        while !cancel_pid.exists() {
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
    let pid = std::fs::read_to_string(&cancel_pid)
        .unwrap()
        .parse::<i32>()
        .unwrap();
    task.abort();
    let _ = task.await;
    tokio::time::timeout(std::time::Duration::from_secs(5), async {
        while unsafe { libc::kill(pid, 0) } == 0 {
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
    })
    .await
    .unwrap();

    // Cancellation must hand the live Child to OwnedChild cleanup, rather than
    // Tokio kill_on_drop reaping the group anchor before its restricted child.
    for cancel in [false, true] {
        let pidfile = dir.join(format!("restricted-cancel-{cancel}.pid"));
        let script = format!(
            "/bin/sleep 60 & echo \"$$ $!\" > '{}'; wait",
            pidfile.display()
        );
        let task = tokio::spawn(async move {
            workspace::run(
                "/tmp",
                "/bin/sh",
                &["-c", &script],
                if cancel { 30 } else { 1 },
            )
            .await
        });
        tokio::time::timeout(std::time::Duration::from_secs(5), async {
            while !pidfile.exists() {
                tokio::time::sleep(std::time::Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        let pids: Vec<i32> = std::fs::read_to_string(&pidfile)
            .unwrap()
            .split_whitespace()
            .map(|v| v.parse().unwrap())
            .collect();
        assert_eq!(pids.len(), 2);
        if cancel {
            task.abort();
            assert!(task.await.unwrap_err().is_cancelled());
        } else {
            assert_eq!(task.await.unwrap().unwrap_err().error, "operation_timeout");
        }
        let cleanup = tokio::time::timeout(std::time::Duration::from_secs(5), async {
            while pids.iter().any(|pid| unsafe { libc::kill(*pid, 0) } == 0) {
                tokio::time::sleep(std::time::Duration::from_millis(20)).await;
            }
        })
        .await;
        if cleanup.is_err() {
            for pid in pids {
                unsafe { libc::kill(pid, libc::SIGKILL) };
            }
        }
        assert!(
            cleanup.is_ok(),
            "restricted child or unreaped leader remains: cancel={cancel}"
        );
    }
    // A restricted native child cannot reliably be rediscovered by reading its env.
    // Keep the exited leader unreaped until the shared owner has stopped its group.
    for status in [0, 7] {
        for attempt in 0..6 {
            let pidfile = dir.join(format!("fast-{status}-{attempt}.pid"));
            let script=format!("/bin/sleep 60 & echo $! > '{}'; printf 'fast-output\\n'; printf 'fixture-error\\n' >&2; exit {status}",pidfile.display());
            let started = std::time::Instant::now();
            let result = workspace::run("/tmp", "/bin/sh", &["-c", &script], 2).await;
            let elapsed = started.elapsed();
            let pid = std::fs::read_to_string(&pidfile)
                .unwrap()
                .trim()
                .parse::<i32>()
                .unwrap();
            // Reparented dead grandchildren may briefly await launchd reap.
            let _ = tokio::time::timeout(std::time::Duration::from_secs(1), async {
                while unsafe { libc::kill(pid, 0) } == 0 {
                    tokio::time::sleep(std::time::Duration::from_millis(10)).await;
                }
            })
            .await;
            let alive = unsafe { libc::kill(pid, 0) } == 0;
            // Clean up only this fixture's child even when the regression reproduces.
            if alive {
                unsafe { libc::kill(pid, libc::SIGKILL) };
            }
            assert!(!alive,"restricted child survived fast leader exit: status={status}, attempt={attempt}, result={result:?}");
            if status == 0 {
                assert_eq!(result.unwrap(), "fast-output\n", "status={status}, attempt={attempt}, elapsed={elapsed:?}");
            } else {
                let error = result.unwrap_err();
                assert_eq!(error.error, "git_failed", "status={status}, attempt={attempt}, elapsed={elapsed:?}, message={}", error.message);
                assert!(error.message.contains("fixture-error"));
            }
        }
    }
    let _ = std::fs::remove_dir_all(dir);
}
