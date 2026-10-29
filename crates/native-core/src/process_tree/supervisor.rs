//! A single crash-surviving native helper, shared by every external child.
use super::{ProcessTree, Result};
use serde_json::{json, Value};
use std::{
    collections::{HashMap, VecDeque},
    path::{Path, PathBuf},
    process::Stdio,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    time::Duration,
};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    sync::{mpsc, oneshot, Notify, OnceCell, OwnedSemaphorePermit, Semaphore},
};

const REQUEST_CREDIT: usize = 128;
const WRITE_QUEUE: usize = 64;
struct Reply {
    sender: Option<oneshot::Sender<Result<Value>>>,
    _credit: Option<OwnedSemaphorePermit>,
}
type Replies = Arc<Mutex<HashMap<String, Reply>>>;
struct DropStop {
    _credit: Option<OwnedSemaphorePermit>,
}
#[derive(Default)]
struct DropQueue {
    entries: HashMap<String, DropStop>,
    ready: VecDeque<String>,
}
impl DropQueue {
    fn clear(&mut self) {
        self.entries.clear();
        self.ready.clear();
    }
}
struct DropStops {
    pending: Mutex<DropQueue>,
    wake: Notify,
    alive: Arc<AtomicBool>,
}
impl DropStops {
    fn enqueue(&self, token: String, credit: Option<OwnedSemaphorePermit>) {
        if !self.alive.load(Ordering::Acquire) {
            return;
        }
        let mut pending = self.pending.lock().unwrap();
        if !self.alive.load(Ordering::Acquire) {
            return;
        }
        if !pending.entries.contains_key(&token) {
            pending.ready.push_back(token.clone());
            pending.entries.insert(token, DropStop { _credit: credit });
        }
        drop(pending);
        self.wake.notify_one();
    }
    fn next(&self) -> Option<Value> {
        let mut pending = self.pending.lock().unwrap();
        let token = pending.ready.pop_front()?;
        Some(json!({"id":format!("drop:{token}"),"op":"stop","token":token}))
    }
    fn acknowledge(&self, id: &str) -> bool {
        if let Some(token) = id.strip_prefix("drop:") {
            self.pending.lock().unwrap().entries.remove(token);
            true
        } else {
            false
        }
    }
}
struct Supervisor {
    binary: PathBuf,
    lock_path: PathBuf,
    outgoing: mpsc::Sender<Value>,
    replies: Replies,
    alive: Arc<AtomicBool>,
    credit: Arc<Semaphore>,
    drops: Arc<DropStops>,
}
static SHARED: OnceCell<Arc<Supervisor>> = OnceCell::const_new();

#[derive(Clone)]
pub struct ProcessReservation(Arc<Reservation>);
struct Reservation {
    token: String,
    supervisor: Arc<Supervisor>,
    registered: AtomicBool,
    stopped: tokio::sync::Mutex<Option<Result<()>>>,
}
impl Drop for Reservation {
    fn drop(&mut self) {
        if self.registered.load(Ordering::Acquire) {
            // One entry per real reservation, retained/coalesced until its ACK.
            // No per-Drop spawned task or unbounded stream of stop messages.
            self.supervisor.drops.enqueue(self.token.clone(), None);
        }
    }
}
impl ProcessReservation {
    pub fn token(&self) -> &str {
        &self.0.token
    }
    pub async fn attach(&self, pid: u32) -> Result<()> {
        self.0
            .supervisor
            .request(json!({"op":"attach","token":self.0.token,"pid":pid}))
            .await
            .map(|_| ())
    }
    pub async fn stop(&self) -> Result<()> {
        let mut stopped = self.0.stopped.lock().await;
        if let Some(result) = &*stopped {
            return result.clone();
        }
        let result = self
            .0
            .supervisor
            .request(json!({"op":"stop","token":self.0.token}))
            .await
            .map(|_| ());
        if result.is_ok() {
            self.0.registered.store(false, Ordering::Release);
        }
        *stopped = Some(result.clone());
        result
    }
}
pub async fn ensure_supervisor(binary: &Path, lock_path: &Path) -> Result<()> {
    let supervisor = SHARED
        .get_or_try_init(|| Supervisor::start(binary, lock_path))
        .await?;
    if supervisor.binary != binary || supervisor.lock_path != lock_path {
        return Err("process supervisor profile already initialized".into());
    }
    supervisor.request(json!({"op":"ready"})).await.map(|_| ())
}
/// Reserve ACK precedes spawn; request credits are released at ACK, not at child
/// exit. The number of live CLI reservations is therefore never capped.
pub async fn reserve() -> Result<ProcessReservation> {
    let supervisor = SHARED
        .get()
        .ok_or("process supervisor not initialized before spawn")?
        .clone();
    let lease = ProcessReservation(Arc::new(Reservation {
        token: uuid::Uuid::new_v4().to_string(),
        supervisor,
        registered: AtomicBool::new(false),
        stopped: tokio::sync::Mutex::new(None),
    }));
    lease
        .0
        .supervisor
        .request(json!({"op":"reserve","token":lease.token()}))
        .await?;
    lease.0.registered.store(true, Ordering::Release);
    Ok(lease)
}
struct Pending {
    id: String,
    replies: Replies,
    credit: Option<OwnedSemaphorePermit>,
    cancel_reserve: Option<String>,
    queued: bool,
    drops: Arc<DropStops>,
}
impl Drop for Pending {
    fn drop(&mut self) {
        if !self.queued {
            self.replies.lock().unwrap().remove(&self.id);
            return;
        }
        if let Some(token) = self.cancel_reserve.take() {
            self.replies.lock().unwrap().remove(&self.id);
            // A cancelled reserve may already exist remotely. Transfer its
            // credit through the compensating stop ACK, not just reserve ACK.
            self.drops.enqueue(token, self.credit.take());
        } else if let Some(reply) = self.replies.lock().unwrap().get_mut(&self.id) {
            // Caller cancellation is not remote completion. Keep transmitted
            // stop/attach credit in the reply table until wire ACK/disconnect.
            reply.sender.take();
        }
    }
}

impl Supervisor {
    async fn start(binary: &Path, lock_path: &Path) -> Result<Arc<Self>> {
        let mut child = tokio::process::Command::new(binary)
            .arg("process-supervisor")
            .arg(lock_path)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .process_group(0)
            .kill_on_drop(false)
            .spawn()
            .map_err(|e| e.to_string())?;
        let mut input = child.stdin.take().ok_or("supervisor stdin")?;
        let output = child.stdout.take().ok_or("supervisor stdout")?;
        let (tx, mut rx) = mpsc::channel::<Value>(WRITE_QUEUE);
        let replies: Replies = Arc::new(Mutex::new(HashMap::new()));
        let alive = Arc::new(AtomicBool::new(true));
        let drops = Arc::new(DropStops {
            pending: Mutex::new(DropQueue::default()),
            wake: Notify::new(),
            alive: alive.clone(),
        });
        let service = Arc::new(Self {
            binary: binary.to_owned(),
            lock_path: lock_path.to_owned(),
            outgoing: tx,
            replies: replies.clone(),
            alive: alive.clone(),
            credit: Arc::new(Semaphore::new(REQUEST_CREDIT)),
            drops: drops.clone(),
        });
        let failed = replies.clone();
        let writer_alive = alive.clone();
        let writer_drops = drops.clone();
        tokio::spawn(async move {
            loop {
                // Cleanup has priority over fresh requests, including a full
                // request queue. No helper operation is cancelled after write.
                let value = if let Some(stop) = writer_drops.next() {
                    stop
                } else {
                    tokio::select! {biased;
                        _=writer_drops.wake.notified()=>continue,
                        value=rx.recv()=>match value{Some(value)=>value,None=>break},
                    }
                };
                // A priority stop may overtake a reserve still in the write
                // queue. A cancelled, unwritten reserve must never be sent
                // afterwards and resurrect the remote reservation.
                if value["op"] == "reserve"
                    && value["id"]
                        .as_str()
                        .is_some_and(|id| !failed.lock().unwrap().contains_key(id))
                {
                    continue;
                }
                let mut bytes = serde_json::to_vec(&value).unwrap();
                bytes.push(b'\n');
                if !matches!(
                    tokio::time::timeout(Duration::from_secs(5), input.write_all(&bytes)).await,
                    Ok(Ok(()))
                ) {
                    break;
                }
            }
            writer_alive.store(false, Ordering::Release);
            fail(&failed, "process supervisor writer closed");
            writer_drops.pending.lock().unwrap().clear();
        });
        tokio::spawn(async move {
            let mut lines = BufReader::new(output).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                let Ok(value) = serde_json::from_str::<Value>(&line) else {
                    break;
                };
                if let Some(id) = value["id"].as_str() {
                    if drops.acknowledge(id) {
                        if value["ok"] != true {
                            eprintln!("native process cleanup failed after Drop");
                        }
                        continue;
                    }
                    finish_reply(&replies, value);
                }
            }
            alive.store(false, Ordering::Release);
            fail(&replies, "process supervisor exited");
            drops.pending.lock().unwrap().clear();
        });
        tokio::spawn(async move {
            let _ = child.wait().await;
        });
        service.request(json!({"op":"ready"})).await?;
        Ok(service)
    }
    async fn request(&self, mut value: Value) -> Result<Value> {
        tokio::time::timeout(Duration::from_secs(8), async {
            if !self.alive.load(Ordering::Acquire) {
                return Err("process supervisor unavailable".into());
            }
            let credit = self
                .credit
                .clone()
                .acquire_owned()
                .await
                .map_err(|_| "process supervisor closed")?;
            if !self.alive.load(Ordering::Acquire) {
                return Err("process supervisor unavailable".into());
            }
            let id = uuid::Uuid::new_v4().to_string();
            value["id"] = json!(id);
            let (tx, rx) = oneshot::channel();
            self.replies.lock().unwrap().insert(
                id.clone(),
                Reply {
                    sender: Some(tx),
                    _credit: None,
                },
            );
            let cancel_reserve = if value["op"] == "reserve" {
                value["token"].as_str().map(str::to_owned)
            } else {
                None
            };
            let mut pending = Pending {
                id,
                replies: self.replies.clone(),
                credit: Some(credit),
                cancel_reserve,
                queued: false,
                drops: self.drops.clone(),
            };
            self.outgoing
                .send(value)
                .await
                .map_err(|_| "process supervisor unavailable")?;
            pending.queued = true;
            if pending.cancel_reserve.is_none() {
                if let Some(reply) = self.replies.lock().unwrap().get_mut(&pending.id) {
                    reply._credit = pending.credit.take();
                }
            }
            let result = rx.await.map_err(|_| "process supervisor disconnected")?;
            if result.is_ok() {
                pending.cancel_reserve = None;
            }
            result
        })
        .await
        .map_err(|_| "process supervisor acknowledgement timeout".to_string())?
    }
}
fn finish_reply(replies: &Replies, value: Value) {
    if let Some(id) = value["id"].as_str() {
        if let Some(mut reply) = replies.lock().unwrap().remove(id) {
            if let Some(tx) = reply.sender.take() {
                let result = if value["ok"] == true {
                    Ok(value)
                } else {
                    Err(value["error"]
                        .as_str()
                        .unwrap_or("process supervisor error")
                        .into())
                };
                let _ = tx.send(result);
            }
        }
    } // Removing the entry releases non-reserve credit even without a waiter.
}
fn fail(replies: &Replies, error: &str) {
    for (_, mut reply) in replies.lock().unwrap().drain() {
        if let Some(tx) = reply.sender.take() {
            let _ = tx.send(Err(error.into()));
        }
    }
}

/// Native main dispatch for `process-supervisor`. stdout is a private JSON ACK
/// pipe. On EOF/termination all reserved identities are stopped before returning.
pub async fn process_supervisor() -> Result<i32> {
    use tokio::signal::unix::{signal, SignalKind};
    let mut term = signal(SignalKind::terminate()).map_err(|e| e.to_string())?;
    let mut hup = signal(SignalKind::hangup()).map_err(|e| e.to_string())?;
    let (tx, mut rx) = mpsc::channel::<Value>(128);
    std::thread::spawn(move || {
        use std::io::{BufRead, Read};
        let stdin = std::io::stdin();
        let mut reader = std::io::BufReader::new(stdin.lock());
        loop {
            let mut line = Vec::new();
            match reader.by_ref().take(16385).read_until(b'\n', &mut line) {
                Ok(0) | Err(_) => break,
                Ok(_) => {}
            }
            if line.len() > 16384 {
                break;
            }
            let Ok(value) = serde_json::from_slice(&line) else {
                break;
            };
            if tx.blocking_send(value).is_err() {
                break;
            }
        }
    });
    let lock_path = std::env::args_os()
        .nth(2)
        .map(PathBuf::from)
        .ok_or("missing supervisor lifetime lock path")?;
    let (locked_tx, mut locked_rx) = oneshot::channel();
    // Blocking flock runs on a detached OS thread: pipe EOF can terminate this
    // helper even while an old instance owns the lock. No startup polling.
    std::thread::spawn(move || {
        use std::os::unix::{
            fs::{MetadataExt, OpenOptionsExt},
            io::AsRawFd,
        };
        let result = (|| -> Result<std::fs::File> {
            let file = std::fs::OpenOptions::new()
                .read(true)
                .write(true)
                .create(true)
                .mode(0o600)
                .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
                .open(lock_path)
                .map_err(|e| e.to_string())?;
            let metadata = file.metadata().map_err(|e| e.to_string())?;
            if !metadata.is_file()
                || metadata.uid() != unsafe { libc::geteuid() }
                || metadata.nlink() != 1
            {
                return Err("unsafe supervisor lifetime lock".into());
            }
            loop {
                if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } == 0 {
                    return Ok(file);
                }
                let error = std::io::Error::last_os_error();
                if error.kind() != std::io::ErrorKind::Interrupted {
                    return Err(error.to_string());
                }
            }
        })();
        let _ = locked_tx.send(result);
    });
    let mut buffered = std::collections::VecDeque::new();
    let _lifetime_lock = loop {
        tokio::select! {
            locked=&mut locked_rx=>break locked.map_err(|_|"supervisor lock thread stopped")??,
            value=rx.recv()=>match value{Some(value) if buffered.len()<128=>buffered.push_back(value),None=>return Ok(0),_=>return Err("supervisor startup queue exceeded".into())},
            _=term.recv()=>return Ok(0),_=hup.recv()=>return Ok(0),
        }
    };
    let trees: Arc<tokio::sync::Mutex<HashMap<String, ProcessTree>>> =
        Arc::new(tokio::sync::Mutex::new(HashMap::new()));
    let output = Arc::new(tokio::sync::Mutex::new(tokio::io::stdout()));
    let mut tasks = tokio::task::JoinSet::new();
    loop {
        // Stop-only traffic must also reap finished tasks; the stop branch
        // continues before the normal command ACK path below.
        while tasks.try_join_next().is_some() {}
        let command = match buffered.pop_front() {
            Some(value) => value,
            None => {
                tokio::select! {
                    value=rx.recv()=>match value{Some(value)=>value,None=>break},
                    _=tasks.join_next(), if !tasks.is_empty()=>continue,
                    _=term.recv()=>break,
                    _=hup.recv()=>break,
                }
            }
        };
        let token = command["token"].as_str().unwrap_or("").to_owned();
        let result = match command["op"].as_str() {
            Some("ready") => Ok(()),
            Some("reserve") if uuid::Uuid::parse_str(&token).is_ok() => {
                let mut trees = trees.lock().await;
                if trees.contains_key(&token) {
                    Ok(())
                } else {
                    match ProcessTree::reserved(token.clone()) {
                        Ok(tree) => {
                            trees.insert(token.clone(), tree);
                            Ok(())
                        }
                        Err(e) => Err(e),
                    }
                }
            }
            Some("attach") => {
                let tree = trees.lock().await.get(&token).cloned();
                match (
                    tree,
                    command["pid"].as_u64().filter(|v| *v <= i32::MAX as u64),
                ) {
                    (Some(tree), Some(pid)) => tree.attach_pid(pid as u32).await,
                    _ => Err("invalid process attachment".into()),
                }
            }
            Some("stop") => {
                // Keep the tree in the map until stop completes, so stdin EOF
                // also awaits already-running stops before the helper exits.
                let tree = trees.lock().await.get(&token).cloned();
                let output = output.clone();
                let trees = trees.clone();
                tasks.spawn(async move {
                    let result = match tree {
                        Some(tree) => tree.stop().await,
                        None => Ok(()),
                    };
                    trees.lock().await.remove(&token);
                    reply(&output, &command, result).await;
                });
                continue;
            }
            _ => Err("invalid process supervisor command".into()),
        };
        reply(&output, &command, result).await;
        while tasks.try_join_next().is_some() {}
    }
    let all: Vec<_> = trees.lock().await.values().cloned().collect();
    let mut error = None;
    for result in futures_util::future::join_all(all.iter().map(ProcessTree::stop)).await {
        if let Err(e) = result {
            error = Some(e);
        }
    }
    while tasks.join_next().await.is_some() {}
    match error {
        Some(e) => Err(e),
        None => Ok(0),
    }
}
async fn reply(
    output: &Arc<tokio::sync::Mutex<tokio::io::Stdout>>,
    command: &Value,
    result: Result<()>,
) {
    if command.get("id").is_none() {
        return;
    }
    let value = match result {
        Ok(()) => json!({"id":command["id"],"ok":true}),
        Err(error) => json!({"id":command["id"],"ok":false,"error":error}),
    };
    let mut bytes = serde_json::to_vec(&value).unwrap();
    bytes.push(b'\n');
    let mut output = output.lock().await;
    let _ = tokio::time::timeout(Duration::from_secs(2), output.write_all(&bytes)).await;
    let _ = tokio::time::timeout(Duration::from_secs(2), output.flush()).await;
}

#[cfg(test)]
mod pressure_tests {
    use super::*;
    fn mock() -> (Arc<Supervisor>, mpsc::Receiver<Value>) {
        let (outgoing, rx) = mpsc::channel(WRITE_QUEUE);
        let alive = Arc::new(AtomicBool::new(true));
        let drops = Arc::new(DropStops {
            pending: Mutex::new(DropQueue::default()),
            wake: Notify::new(),
            alive: alive.clone(),
        });
        (
            Arc::new(Supervisor {
                binary: PathBuf::new(),
                lock_path: PathBuf::new(),
                outgoing,
                replies: Arc::new(Mutex::new(HashMap::new())),
                alive,
                credit: Arc::new(Semaphore::new(REQUEST_CREDIT)),
                drops,
            }),
            rx,
        )
    }
    #[tokio::test]
    async fn cancel_storm_retains_bounded_credit_until_coalesced_stop_ack() {
        let (service, mut rx) = mock();
        let mut tasks = tokio::task::JoinSet::new();
        for _ in 0..1000 {
            let s = service.clone();
            tasks.spawn(async move {
                s.request(json!({"op":"reserve","token":uuid::Uuid::new_v4().to_string()}))
                    .await
            });
        }
        tokio::time::timeout(Duration::from_secs(2), async {
            while service.replies.lock().unwrap().len() < REQUEST_CREDIT {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        assert_eq!(rx.len(), WRITE_QUEUE);
        assert_eq!(service.credit.available_permits(), 0);
        tasks.abort_all();
        while tasks.join_next().await.is_some() {}
        assert_eq!(service.replies.lock().unwrap().len(), 0);
        assert_eq!(
            service.drops.pending.lock().unwrap().entries.len(),
            WRITE_QUEUE
        );
        assert_eq!(
            service.credit.available_permits(),
            REQUEST_CREDIT - WRITE_QUEUE
        );
        // Unwritten cancelled reserve records are skipped, even if priority
        // stop ACK arrives before they are pulled off the bounded queue.
        while let Ok(value) = rx.try_recv() {
            assert!(!service
                .replies
                .lock()
                .unwrap()
                .contains_key(value["id"].as_str().unwrap()));
        }
        while let Some(value) = service.drops.next() {
            let id = value["id"].as_str().unwrap();
            assert!(service.drops.acknowledge(id));
        }
        assert_eq!(service.credit.available_permits(), REQUEST_CREDIT);
        let token = uuid::Uuid::new_v4().to_string();
        for _ in 0..10000 {
            service.drops.enqueue(token.clone(), None);
        }
        assert_eq!(service.drops.pending.lock().unwrap().entries.len(), 1);
        assert!(service.drops.next().is_some());
        assert!(service.drops.next().is_none());
        service.drops.acknowledge(&format!("drop:{token}"));
        assert!(service.drops.pending.lock().unwrap().entries.is_empty());
    }
    #[tokio::test]
    async fn cancelled_stop_and_attach_keep_wire_credit_until_ack() {
        for op in ["stop", "attach"] {
            let (service, mut rx) = mock();
            let lease = ProcessReservation(Arc::new(Reservation {
                token: uuid::Uuid::new_v4().to_string(),
                supervisor: service.clone(),
                registered: AtomicBool::new(true),
                stopped: tokio::sync::Mutex::new(None),
            }));
            let mut sent = Vec::new();
            // Simulate a helper consuming immediately but taking a long time
            // to stop. Cancel each public future after it reached the wire.
            for _ in 0..REQUEST_CREDIT {
                let l = lease.clone();
                let task = tokio::spawn(async move {
                    if op == "stop" {
                        l.stop().await
                    } else {
                        l.attach(123).await
                    }
                });
                let value = tokio::time::timeout(Duration::from_secs(1), rx.recv())
                    .await
                    .unwrap()
                    .unwrap();
                assert_eq!(value["op"], op);
                sent.push(value);
                task.abort();
                let _ = task.await;
            }
            assert_eq!(service.credit.available_permits(), 0);
            assert_eq!(service.replies.lock().unwrap().len(), REQUEST_CREDIT);
            for _ in 0..1000 {
                let l = lease.clone();
                let task = tokio::spawn(async move {
                    if op == "stop" {
                        l.stop().await
                    } else {
                        l.attach(123).await
                    }
                });
                tokio::task::yield_now().await;
                task.abort();
                let _ = task.await;
            }
            assert!(
                rx.try_recv().is_err(),
                "cancelled callers bypassed admission"
            );
            assert_eq!(service.replies.lock().unwrap().len(), REQUEST_CREDIT);
            for value in sent {
                finish_reply(&service.replies, json!({"id":value["id"],"ok":true}));
            }
            assert_eq!(service.credit.available_permits(), REQUEST_CREDIT);
            assert!(service.replies.lock().unwrap().is_empty());
            // Once ACKs arrive, new work is admitted normally.
            let l = lease.clone();
            let task = tokio::spawn(async move { l.stop().await });
            let value = rx.recv().await.unwrap();
            finish_reply(&service.replies, json!({"id":value["id"],"ok":true}));
            task.await.unwrap().unwrap();
        }
    }
    #[tokio::test]
    async fn request_backpressure_does_not_cap_live_reservations() {
        let (service, mut rx) = mock();
        let responder = service.clone();
        let task = tokio::spawn(async move {
            while let Some(value) = rx.recv().await {
                finish_reply(&responder.replies, json!({"id":value["id"],"ok":true}));
            }
        });
        let mut leases = Vec::new();
        for _ in 0..REQUEST_CREDIT * 2 {
            let token = uuid::Uuid::new_v4().to_string();
            service
                .request(json!({"op":"reserve","token":token}))
                .await
                .unwrap();
            leases.push(ProcessReservation(Arc::new(Reservation {
                token,
                supervisor: service.clone(),
                registered: AtomicBool::new(true),
                stopped: tokio::sync::Mutex::new(None),
            })));
        }
        assert_eq!(leases.len(), REQUEST_CREDIT * 2);
        assert_eq!(service.credit.available_permits(), REQUEST_CREDIT);
        drop(leases);
        assert_eq!(
            service.drops.pending.lock().unwrap().entries.len(),
            REQUEST_CREDIT * 2
        );
        while let Some(value) = service.drops.next() {
            service.drops.acknowledge(value["id"].as_str().unwrap());
        }
        task.abort();
        let _ = task.await;
    }
}
