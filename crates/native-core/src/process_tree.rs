//! Native process ownership. One kqueue/thread per daemon, no ps subprocesses.
//! NOTE_TRACK/NOTE_CHILD are intentionally not used (unsupported on Darwin).
//! Pass a fresh OWNER_ENV token before spawn and attach immediately afterwards.
//! Token inheritance recovers setsid/double-fork descendants whose ancestry was
//! already reparented before NOTE_FORK delivery. This is cooperative ownership,
//! not a sandbox: processes deliberately clearing the token before an unseen
//! fork, privileged descendants, and SIGKILL of the owner itself are boundaries.
use std::{
    collections::{HashMap, HashSet},
    sync::{mpsc, Arc, OnceLock},
    time::{Duration, Instant},
};
use tokio::sync::{oneshot, Mutex};
#[path = "process_tree/supervisor.rs"]
mod supervisor;
pub use supervisor::{ensure_supervisor, process_supervisor, reserve, ProcessReservation};
pub const OWNER_ENV: &str = "NEURA_PROCESS_OWNER";
type Result<T> = std::result::Result<T, String>;

#[derive(Clone)]
pub struct ProcessTree(Arc<Lease>);
struct Lease {
    id: String,
    monitor: &'static Monitor,
    stopped: Mutex<Option<Result<()>>>,
}
impl Drop for Lease {
    fn drop(&mut self) {
        self.monitor.send(Control::Stop(self.id.clone(), None));
    }
}
impl ProcessTree {
    /// Ancestry only. Prefer new_with_token for processes that may detach.
    pub fn new(pid: u32) -> Result<Self> {
        Self::attach(pid, None, None)
    }
    pub fn new_with_token(pid: u32, token: String) -> Result<Self> {
        if uuid::Uuid::parse_str(&token).is_err() {
            return Err("invalid process owner token".into());
        }
        Self::attach(pid, Some(token), None)
    }
    fn attach(pid: u32, token: Option<String>, group: Option<Identity>) -> Result<Self> {
        if (pid <= 1 && token.is_none()) || pid == std::process::id() {
            return Err("refusing to own self/init".into());
        }
        let monitor = MONITOR
            .get_or_init(Monitor::new)
            .as_ref()
            .map_err(Clone::clone)?;
        let id = uuid::Uuid::new_v4().to_string();
        let (tx, rx) = mpsc::sync_channel(1);
        monitor.send(Control::Add(id.clone(), pid, token, group, tx));
        rx.recv().map_err(|_| "process monitor stopped")??;
        Ok(Self(Arc::new(Lease {
            id,
            monitor,
            stopped: Mutex::new(None),
        })))
    }
    fn reserved(token: String) -> Result<Self> {
        Self::attach(0, Some(token), None)
    }
    async fn attach_pid(&self, pid: u32) -> Result<()> {
        if pid <= 1 || pid == std::process::id() {
            return Err("invalid attach pid".into());
        }
        let (tx, rx) = oneshot::channel();
        self.0
            .monitor
            .send(Control::Attach(self.0.id.clone(), pid, tx));
        rx.await
            .map_err(|_| "process monitor stopped".to_string())?
    }
    /// Idempotent and cancellation-safe. TERM once, KILL after 1.5 seconds;
    /// resolves after every discovered identity has exited, or returns an error.
    pub async fn stop(&self) -> Result<()> {
        let mut result = self.0.stopped.lock().await;
        if let Some(result) = &*result {
            return result.clone();
        }
        let (tx, rx) = oneshot::channel();
        self.0
            .monitor
            .send(Control::Stop(self.0.id.clone(), Some(tx)));
        let value = rx
            .await
            .map_err(|_| "process monitor stopped".to_string())?;
        *result = Some(value.clone());
        value
    }
}
static MONITOR: OnceLock<Result<Monitor>> = OnceLock::new();
struct Monitor {
    tx: mpsc::Sender<Control>,
    kq: i32,
}
enum Control {
    Attach(String, u32, oneshot::Sender<Result<()>>),
    Add(
        String,
        u32,
        Option<String>,
        Option<Identity>,
        mpsc::SyncSender<Result<()>>,
    ),
    Stop(String, Option<oneshot::Sender<Result<()>>>),
}
struct Tree {
    group: Option<Identity>,
    token: Option<String>,
    owned: HashMap<u64, Identity>,
    stopping: Option<Instant>,
    termed: HashSet<u64>,
    killed: HashSet<u64>,
    waiters: Vec<oneshot::Sender<Result<()>>>,
    error: Option<String>,
}
#[derive(Clone, Copy, Debug)]
struct Identity {
    pid: i32,
    unique: u64,
    parent: u64,
    version: u32,
    uid: u32,
    group: i32,
    zombie: bool,
}
#[repr(C)]
#[derive(Default)]
struct Unique {
    uuid: [u8; 16],
    unique: u64,
    parent: u64,
    version: i32,
    original_parent_version: i32,
    reserved: [u64; 2],
}
#[repr(C)]
struct BsdUnique {
    bsd: libc::proc_bsdinfo,
    unique: Unique,
}
extern "C" {
    fn proc_signal_with_audittoken(token: *const [u32; 8], signal: i32) -> i32;
}
fn identity(pid: i32) -> Option<Identity> {
    // XNU PROC_PIDT_BSDINFOWITHUNIQID=18 returns both atomically, avoiding
    // mismatched PID generation between two independent proc_pidinfo calls.
    let mut info: BsdUnique = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<BsdUnique>();
    let n = unsafe { libc::proc_pidinfo(pid, 18, 0, &mut info as *mut _ as *mut _, size as i32) };
    if n != size as i32 {
        return None;
    }
    Some(Identity {
        pid,
        unique: info.unique.unique,
        parent: info.unique.parent,
        version: info.unique.version as u32,
        uid: info.bsd.pbi_uid,
        group: info.bsd.pbi_pgid as i32,
        zombie: info.bsd.pbi_status == 5,
    })
}
fn signal(identity: Identity, signal: i32) -> Result<()> {
    if identity.pid <= 1 || identity.pid == std::process::id() as i32 {
        return Err("unsafe signal target".into());
    }
    let mut token = [0u32; 8];
    token[5] = identity.pid as u32;
    token[7] = identity.version;
    // The kernel checks pidversion while holding the process reference. Never
    // fall back to kill(pid), whose check-then-signal race can hit a reused PID.
    if unsafe { proc_signal_with_audittoken(&token, signal) } == 0 {
        return Ok(());
    }
    let error = std::io::Error::last_os_error();
    if error.raw_os_error() == Some(libc::ESRCH) {
        Ok(())
    } else {
        Err(format!("signal {}: {error}", identity.pid))
    }
}
#[cfg(test)]
static SNAPSHOTS: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
fn snapshot() -> Result<Vec<Identity>> {
    #[cfg(test)]
    SNAPSHOTS.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let count = unsafe { libc::proc_listallpids(std::ptr::null_mut(), 0) };
    if count <= 0 {
        return Err(std::io::Error::last_os_error().to_string());
    }
    let mut pids = vec![0i32; count as usize + 256];
    loop {
        let count =
            unsafe { libc::proc_listallpids(pids.as_mut_ptr() as *mut _, (pids.len() * 4) as i32) };
        if count < 0 {
            return Err(std::io::Error::last_os_error().to_string());
        }
        if count as usize >= pids.len() {
            pids.resize(pids.len() * 2, 0);
            continue;
        }
        pids.truncate(count as usize);
        break;
    }
    Ok(pids
        .into_iter()
        .filter(|pid| *pid > 1)
        .filter_map(identity)
        .collect())
}
fn owner(pid: i32, buffer: &mut [u8]) -> Option<String> {
    let mut mib = [libc::CTL_KERN, libc::KERN_PROCARGS2, pid];
    let mut size = buffer.len();
    if unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            3,
            buffer.as_mut_ptr() as *mut _,
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    } != 0
        || size < 4
    {
        return None;
    }
    let argc = i32::from_ne_bytes(buffer[..4].try_into().ok()?);
    if argc < 0 {
        return None;
    }
    let bytes = &buffer[4..size];
    let mut pos = bytes.iter().position(|x| *x == 0)?;
    while bytes.get(pos) == Some(&0) {
        pos += 1;
    }
    for _ in 0..argc {
        pos += bytes.get(pos..)?.iter().position(|x| *x == 0)? + 1;
    }
    // Retain only our UUID; never log or retain other process environment values.
    for entry in bytes.get(pos..)?.split(|x| *x == 0) {
        if let Some(value) = entry.strip_prefix(b"NEURA_PROCESS_OWNER=") {
            let value = std::str::from_utf8(value).ok()?;
            return uuid::Uuid::parse_str(value).ok().map(|_| value.to_owned());
        }
    }
    None
}
fn event(kq: i32, ident: usize, filter: i16, flags: u16, fflags: u32) -> Result<()> {
    let change = libc::kevent {
        ident,
        filter,
        flags,
        fflags,
        data: 0,
        udata: std::ptr::null_mut(),
    };
    if unsafe { libc::kevent(kq, &change, 1, std::ptr::null_mut(), 0, std::ptr::null()) } < 0 {
        return Err(std::io::Error::last_os_error().to_string());
    }
    Ok(())
}
impl Monitor {
    fn new() -> Result<Self> {
        identity(std::process::id() as i32).ok_or("native process identity unavailable")?;
        let kq = unsafe { libc::kqueue() };
        if kq < 0 {
            return Err(std::io::Error::last_os_error().to_string());
        }
        unsafe {
            libc::fcntl(kq, libc::F_SETFD, libc::FD_CLOEXEC);
        }
        if let Err(e) = event(kq, 1, libc::EVFILT_USER, libc::EV_ADD | libc::EV_CLEAR, 0) {
            unsafe {
                libc::close(kq);
            }
            return Err(e);
        }
        let (tx, rx) = mpsc::channel();
        std::thread::Builder::new()
            .name("neura-process-owner".into())
            .spawn(move || monitor(kq, rx))
            .map_err(|e| e.to_string())?;
        Ok(Self { tx, kq })
    }
    fn send(&self, command: Control) {
        let _ = self.tx.send(command);
        let _ = event(self.kq, 1, libc::EVFILT_USER, 0, libc::NOTE_TRIGGER);
    }
}
fn monitor(kq: i32, rx: mpsc::Receiver<Control>) {
    let mut trees: HashMap<String, Tree> = HashMap::new();
    let mut watched: HashMap<i32, u64> = HashMap::new();
    let mut tokens: HashMap<(u64, u32), Option<String>> = HashMap::new();
    let mut buffer = vec![0u8; 1024 * 1024];
    let mut events: [libc::kevent; 128] = unsafe { std::mem::zeroed() };
    loop {
        for command in rx.try_iter() {
            match command {
                Control::Add(id, pid, token, group, ack) => {
                    let root = identity(pid as i32);
                    if root.is_none() && token.is_none() {
                        let _ = ack.send(Err("process already exited".into()));
                        continue;
                    }
                    let mut owned = HashMap::new();
                    if let Some(root) = root {
                        owned.insert(root.unique, root);
                    }
                    trees.insert(
                        id,
                        Tree {
                            group: group.or_else(|| root.filter(|r| r.pid == r.group)),
                            token,
                            owned,
                            stopping: None,
                            termed: HashSet::new(),
                            killed: HashSet::new(),
                            waiters: vec![],
                            error: None,
                        },
                    );
                    let _ = ack.send(Ok(()));
                }
                Control::Attach(id, pid, ack) => {
                    let result = if let Some(tree) = trees.get_mut(&id) {
                        if tree.stopping.is_some() {
                            Err("process lease already stopping".into())
                        } else {
                            if let Some(root) = identity(pid as i32) {
                                if root.pid == root.group {
                                    tree.group = Some(root);
                                }
                                tree.owned.insert(root.unique, root);
                            }
                            Ok(())
                        }
                    } else {
                        Err("unknown process lease".into())
                    };
                    let _ = ack.send(result);
                }
                Control::Stop(id, waiter) => {
                    if let Some(tree) = trees.get_mut(&id) {
                        tree.stopping.get_or_insert_with(Instant::now);
                        if let Some(waiter) = waiter {
                            tree.waiters.push(waiter);
                        }
                    } else if let Some(waiter) = waiter {
                        let _ = waiter.send(Ok(()));
                    }
                }
            }
        }
        if !trees.is_empty() {
            match snapshot() {
                Ok(rows) => {
                    let live: HashSet<u64> = rows
                        .iter()
                        .filter(|r| !r.zombie)
                        .map(|r| r.unique)
                        .collect();
                    let generations: HashSet<(u64, u32)> =
                        rows.iter().map(|row| (row.unique, row.version)).collect();
                    tokens.retain(|key, _| generations.contains(key));
                    let uid = unsafe { libc::geteuid() };
                    let scan_tokens = trees.values().any(|t| t.token.is_some());
                    if scan_tokens {
                        for row in &rows {
                            if row.uid == uid && !row.zombie {
                                tokens
                                    .entry((row.unique, row.version))
                                    .or_insert_with(|| owner(row.pid, &mut buffer));
                            }
                        }
                    }
                    for tree in trees.values_mut() {
                        // Claim group members only while its original dedicated leader
                        // is alive. A cached numeric PGID alone is never ownership proof.
                        let anchored_group = tree
                            .group
                            .filter(|leader| {
                                rows.iter().any(|r| {
                                    r.pid == leader.pid && r.unique == leader.unique && !r.zombie
                                })
                            })
                            .map(|r| r.pid);
                        for row in &rows {
                            if let Some(previous) = tree.owned.get_mut(&row.unique) {
                                if previous.version != row.version {
                                    tree.termed.remove(&row.unique);
                                    tree.killed.remove(&row.unique);
                                }
                                *previous = *row;
                            }
                        }
                        loop {
                            let mut added = false;
                            for row in &rows {
                                if row.pid == std::process::id() as i32
                                    || row.zombie
                                    || tree.owned.contains_key(&row.unique)
                                {
                                    continue;
                                }
                                if tree.owned.contains_key(&row.parent)
                                    || anchored_group == Some(row.group)
                                    || (tree.token.is_some()
                                        && tokens
                                            .get(&(row.unique, row.version))
                                            .and_then(|x| x.as_ref())
                                            == tree.token.as_ref())
                                {
                                    tree.owned.insert(row.unique, *row);
                                    added = true;
                                }
                            }
                            if !added {
                                break;
                            }
                        }
                        tree.owned.retain(|id, _| live.contains(id));
                        for row in tree.owned.values() {
                            if watched.get(&row.pid) != Some(&row.unique) {
                                if event(
                                    kq,
                                    row.pid as usize,
                                    libc::EVFILT_PROC,
                                    libc::EV_ADD | libc::EV_CLEAR,
                                    libc::NOTE_FORK | libc::NOTE_EXEC | libc::NOTE_EXIT,
                                )
                                .is_ok()
                                {
                                    watched.insert(row.pid, row.unique);
                                }
                            }
                            if let Some(start) = tree.stopping {
                                let kill = start.elapsed() >= Duration::from_millis(1500);
                                let sent = if kill {
                                    &mut tree.killed
                                } else {
                                    &mut tree.termed
                                };
                                if sent.insert(row.unique) {
                                    if let Err(e) = signal(
                                        *row,
                                        if kill { libc::SIGKILL } else { libc::SIGTERM },
                                    ) {
                                        tree.error = Some(e);
                                    }
                                }
                            }
                        }
                    }
                    // Remove obsolete subscriptions, including detached trees after cleanup.
                    let owned: HashSet<u64> = trees
                        .values()
                        .flat_map(|t| t.owned.keys().copied())
                        .collect();
                    watched.retain(|pid, id| {
                        if owned.contains(id) {
                            true
                        } else {
                            let _ = event(kq, *pid as usize, libc::EVFILT_PROC, libc::EV_DELETE, 0);
                            false
                        }
                    });
                }
                Err(error) => {
                    for tree in trees.values_mut() {
                        tree.error = Some(error.clone());
                    }
                }
            }
            trees.retain(|_, tree| {
                if let Some(start) = tree.stopping {
                    if tree.owned.is_empty() || start.elapsed() >= Duration::from_millis(3500) {
                        let result = if !tree.owned.is_empty() {
                            Err(tree.error.clone().unwrap_or_else(|| {
                                "owned processes did not exit before deadline".into()
                            }))
                        } else if let Some(e) = tree.error.take() {
                            Err(e)
                        } else {
                            Ok(())
                        };
                        for waiter in tree.waiters.drain(..) {
                            let _ = waiter.send(result.clone());
                        }
                        return false;
                    }
                }
                true
            });
        }
        if trees.is_empty() {
            for pid in watched.keys() {
                let _ = event(kq, *pid as usize, libc::EVFILT_PROC, libc::EV_DELETE, 0);
            }
            watched.clear();
            tokens.clear();
        }
        let timeout = trees
            .values()
            .filter_map(|t| {
                t.stopping.map(|start| {
                    let elapsed = start.elapsed();
                    if elapsed < Duration::from_millis(1500) {
                        Duration::from_millis(1500) - elapsed
                    } else {
                        Duration::from_millis(3500).saturating_sub(elapsed)
                    }
                })
            })
            .min()
            .unwrap_or(Duration::from_secs(60));
        let ts = libc::timespec {
            tv_sec: timeout.as_secs() as _,
            tv_nsec: timeout.subsec_nanos() as _,
        };
        let n = unsafe {
            libc::kevent(
                kq,
                std::ptr::null(),
                0,
                events.as_mut_ptr(),
                events.len() as i32,
                if trees.is_empty() {
                    std::ptr::null()
                } else {
                    &ts
                },
            )
        };
        if n > 0 {
            for ev in &events[..n as usize] {
                if ev.filter == libc::EVFILT_PROC && ev.fflags & libc::NOTE_EXEC != 0 {
                    if let Some(id) = watched.get(&(ev.ident as i32)) {
                        tokens.retain(|(unique, _), _| unique != id);
                    }
                }
            }
        }
    }
}

/// CLI dispatch: provider-host <program> <args...>. Parent must retain host
/// stdin exclusively; EOF (including parent crash) initiates owned tree cleanup.
pub async fn provider_host(program: String, args: Vec<String>) -> Result<i32> {
    use std::{os::unix::process::ExitStatusExt, process::Stdio};
    use tokio::signal::unix::{signal, SignalKind};
    let mut term = signal(SignalKind::terminate()).map_err(|e| e.to_string())?;
    let mut hup = signal(SignalKind::hangup()).map_err(|e| e.to_string())?;
    let mut interrupt = signal(SignalKind::interrupt()).map_err(|e| e.to_string())?;
    // Keep a dedicated group leader alive through cleanup, even after the
    // program exits before its children can be observed. Never join caller PGID.
    if unsafe { libc::getpgrp() } != std::process::id() as i32
        && unsafe { libc::setpgid(0, 0) } != 0
    {
        return Err(std::io::Error::last_os_error().to_string());
    }
    let group = identity(std::process::id() as i32).ok_or("missing host identity")?;
    let token = uuid::Uuid::new_v4().to_string();
    let mut child = tokio::process::Command::new(program)
        .args(args)
        .env(OWNER_ENV, &token)
        .stdin(Stdio::null())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| e.to_string())?;
    let tree = match ProcessTree::attach(
        child.id().ok_or("missing child pid")?,
        Some(token),
        Some(group),
    ) {
        Ok(tree) => tree,
        Err(e) => {
            let _ = child.kill().await;
            return Err(e);
        }
    };
    // tokio::io::stdin uses a blocking read that can prevent runtime shutdown.
    // A detached OS thread owns only fd0 and wakes once; it cannot keep exit alive.
    let (eof_tx, eof_rx) = oneshot::channel();
    std::thread::spawn(move || {
        use std::io::Read;
        let mut data = [0u8; 256];
        loop {
            match std::io::stdin().read(&mut data) {
                Ok(0) | Err(_) => break,
                Ok(_) => {}
            }
        }
        let _ = eof_tx.send(());
    });
    let status = tokio::select! {
        result=child.wait()=>Some(result.map_err(|e|e.to_string())?),
        _=eof_rx=>None,_=term.recv()=>None,_=hup.recv()=>None,_=interrupt.recv()=>None,
    };
    tree.stop().await?;
    let status = match status {
        Some(status) => status,
        None => tokio::time::timeout(Duration::from_secs(2), child.wait())
            .await
            .map_err(|_| "child reap deadline")?
            .map_err(|e| e.to_string())?,
    };
    Ok(status
        .code()
        .unwrap_or_else(|| 128 + status.signal().unwrap_or(0)))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn idle_ten_twenty_thirty_two_trees_do_not_poll_or_spawn_ps() {
        const CHILD: &str = "NEURA_PROCESS_IDLE_TEST_CHILD";
        if std::env::var_os(CHILD).is_none() {
            let status = std::process::Command::new(std::env::current_exe().unwrap())
                .args([
                    "process_tree::tests::idle_ten_twenty_thirty_two_trees_do_not_poll_or_spawn_ps",
                    "--exact",
                    "--nocapture",
                ])
                .env(CHILD, "1")
                .status()
                .unwrap();
            assert!(status.success());
            return;
        }
        for count in [10, 20, 32] {
            let mut trees = Vec::new();
            let mut children = Vec::new();
            for _ in 0..count {
                let token = uuid::Uuid::new_v4().to_string();
                let child = tokio::process::Command::new("/bin/sleep")
                    .arg("30")
                    .env(OWNER_ENV, &token)
                    .spawn()
                    .unwrap();
                trees.push(ProcessTree::new_with_token(child.id().unwrap(), token).unwrap());
                children.push(child);
            }
            tokio::time::sleep(Duration::from_millis(300)).await;
            let before = SNAPSHOTS.load(std::sync::atomic::Ordering::Relaxed);
            tokio::time::sleep(Duration::from_millis(1600)).await;
            let idle = SNAPSHOTS.load(std::sync::atomic::Ordering::Relaxed) - before;
            eprintln!("{count} native trees: idle snapshots={idle}, former 250ms ps baseline >= {} per 1.6s",count*6);
            assert_eq!(idle, 0);
            for result in futures_util::future::join_all(trees.iter().map(ProcessTree::stop)).await
            {
                result.unwrap();
            }
            for mut child in children {
                child.wait().await.unwrap();
            }
        }
    }
    #[test]
    fn exec_cache_fixture() {
        if std::env::var("NEURA_EXEC_FIXTURE").as_deref() == Ok("1") {
            std::thread::sleep(Duration::from_secs(30));
        }
    }
    #[test]
    fn exec_generation_refreshes_negative_ownership_cache() {
        use std::io::Write;
        let token = uuid::Uuid::new_v4().to_string();
        let mut child = std::process::Command::new("/bin/sh")
            .args([
                "-c",
                "read gate; exec /usr/bin/env NEURA_PROCESS_OWNER=$1 NEURA_EXEC_FIXTURE=1 \"$2\" process_tree::tests::exec_cache_fixture --exact",
                "fixture",
                &token,
                std::env::current_exe().unwrap().to_str().unwrap(),
            ])
            .env_remove(OWNER_ENV)
            .stdin(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        let mut buffer = vec![0; 1024 * 1024];
        let before = identity(child.id() as i32).unwrap();
        let mut cache = HashMap::new();
        cache.insert(
            (before.unique, before.version),
            owner(before.pid, &mut buffer),
        );
        assert_eq!(cache[&(before.unique, before.version)], None);
        child.stdin.take().unwrap().write_all(b"go\n").unwrap();
        let deadline = Instant::now() + Duration::from_secs(3);
        loop {
            let after = identity(child.id() as i32).unwrap();
            let cached = cache
                .entry((after.unique, after.version))
                .or_insert_with(|| owner(after.pid, &mut buffer));
            if cached.as_deref() == Some(&token) {
                assert_ne!(
                    (before.unique, before.version),
                    (after.unique, after.version)
                );
                break;
            }
            if Instant::now() > deadline {
                let uncached = owner(after.pid, &mut buffer);
                let _ = child.kill();
                panic!("exec generation retained stale ownership cache: before={before:?} after={after:?} uncached={:?}", uncached);
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        child.kill().unwrap();
        child.wait().unwrap();
    }
    #[test]
    fn audit_generation_rejects_reused_pid_without_signalling_live_process() {
        let mut child = std::process::Command::new("/bin/sleep")
            .arg("30")
            .spawn()
            .unwrap();
        let real = identity(child.id() as i32).unwrap();
        let mut stale = real;
        stale.version = stale.version.wrapping_add(1);
        signal(stale, libc::SIGKILL).unwrap();
        assert!(child.try_wait().unwrap().is_none());
        signal(real, libc::SIGKILL).unwrap();
        child.wait().unwrap();
    }
    #[tokio::test]
    async fn concurrent_stop_and_final_drop_reap_owned_children() {
        for drop_only in [false, true] {
            let token = uuid::Uuid::new_v4().to_string();
            let mut child = tokio::process::Command::new("/bin/sleep")
                .arg("30")
                .env(OWNER_ENV, &token)
                .spawn()
                .unwrap();
            let tree = ProcessTree::new_with_token(child.id().unwrap(), token).unwrap();
            if drop_only {
                drop(tree);
            } else {
                let copy = tree.clone();
                let (a, b) = tokio::join!(tree.stop(), copy.stop());
                a.unwrap();
                b.unwrap();
                tree.stop().await.unwrap();
            }
            tokio::time::timeout(Duration::from_secs(5), child.wait())
                .await
                .unwrap()
                .unwrap();
        }
    }
}
