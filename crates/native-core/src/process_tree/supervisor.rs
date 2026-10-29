//! A single crash-surviving native helper, shared by every external child.
use super::{ProcessTree, Result};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    process::Stdio,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    time::Duration,
};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    sync::{mpsc, oneshot, OnceCell},
};

type Replies = Arc<Mutex<HashMap<String, oneshot::Sender<Result<Value>>>>>;
struct Supervisor {
    outgoing: mpsc::UnboundedSender<Value>,
    replies: Replies,
    alive: Arc<AtomicBool>,
}
static SHARED: OnceCell<Arc<Supervisor>> = OnceCell::const_new();

#[derive(Clone)]
pub struct ProcessReservation(Arc<Reservation>);
struct Reservation {
    token: String,
    supervisor: Arc<Supervisor>,
    stopped: tokio::sync::Mutex<Option<Result<()>>>,
}
impl Drop for Reservation {
    fn drop(&mut self) {
        // At most one small lifecycle message per lease, no token/output data.
        // This queue scales with actual live reservations, never caps parallelism.
        let _ = self
            .supervisor
            .outgoing
            .send(json!({"op":"stop","token":self.token}));
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
        *stopped = Some(result.clone());
        result
    }
}
/// Reserve and acknowledge ownership before spawning. The returned lease's
/// token must be injected using OWNER_ENV. Attach immediately after spawn.
pub async fn reserve() -> Result<ProcessReservation> {
    let supervisor = SHARED.get_or_try_init(Supervisor::start).await?.clone();
    let lease = ProcessReservation(Arc::new(Reservation {
        token: uuid::Uuid::new_v4().to_string(),
        supervisor,
        stopped: tokio::sync::Mutex::new(None),
    }));
    // Construct the Drop guard before awaiting: cancelled reservations are stopped.
    lease
        .0
        .supervisor
        .request(json!({"op":"reserve","token":lease.token()}))
        .await?;
    Ok(lease)
}
impl Supervisor {
    async fn start() -> Result<Arc<Self>> {
        // Direct native dispatch; never put the helper inside provider-host.
        let mut child =
            tokio::process::Command::new(std::env::current_exe().map_err(|e| e.to_string())?)
                .arg("process-supervisor")
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::inherit())
                .process_group(0)
                .kill_on_drop(false)
                .spawn()
                .map_err(|e| e.to_string())?;
        let mut input = child.stdin.take().ok_or("supervisor stdin")?;
        let output = child.stdout.take().ok_or("supervisor stdout")?;
        let (tx, mut rx) = mpsc::unbounded_channel::<Value>();
        let replies: Replies = Arc::new(Mutex::new(HashMap::new()));
        let alive = Arc::new(AtomicBool::new(true));
        let service = Arc::new(Self {
            outgoing: tx,
            replies: replies.clone(),
            alive: alive.clone(),
        });
        let failed = replies.clone();
        let writer_alive = alive.clone();
        tokio::spawn(async move {
            while let Some(value) = rx.recv().await {
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
            // Dropping stdin is the crash lease; helper cleans all reservations.
        });
        tokio::spawn(async move {
            let mut lines = BufReader::new(output).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                let Ok(value) = serde_json::from_str::<Value>(&line) else {
                    break;
                };
                if let Some(id) = value["id"].as_str() {
                    if let Some(tx) = replies.lock().unwrap().remove(id) {
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
            }
            alive.store(false, Ordering::Release);
            fail(&replies, "process supervisor exited");
        });
        tokio::spawn(async move {
            let _ = child.wait().await;
        });
        Ok(service)
    }
    async fn request(&self, mut value: Value) -> Result<Value> {
        if !self.alive.load(Ordering::Acquire) {
            return Err("process supervisor unavailable".into());
        }
        let id = uuid::Uuid::new_v4().to_string();
        value["id"] = json!(id);
        let (tx, rx) = oneshot::channel();
        self.replies.lock().unwrap().insert(id.clone(), tx);
        struct Pending {
            id: String,
            replies: Replies,
        }
        impl Drop for Pending {
            fn drop(&mut self) {
                self.replies.lock().unwrap().remove(&self.id);
            }
        }
        let _pending = Pending {
            id,
            replies: self.replies.clone(),
        };
        self.outgoing
            .send(value)
            .map_err(|_| "process supervisor unavailable")?;
        tokio::time::timeout(Duration::from_secs(8), rx)
            .await
            .map_err(|_| "process supervisor acknowledgement timeout")?
            .map_err(|_| "process supervisor disconnected")?
    }
}
fn fail(replies: &Replies, error: &str) {
    for (_, tx) in replies.lock().unwrap().drain() {
        let _ = tx.send(Err(error.into()));
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
    let trees: Arc<tokio::sync::Mutex<HashMap<String, ProcessTree>>> =
        Arc::new(tokio::sync::Mutex::new(HashMap::new()));
    let output = Arc::new(tokio::sync::Mutex::new(tokio::io::stdout()));
    let mut tasks = tokio::task::JoinSet::new();
    loop {
        let command = tokio::select! {value=rx.recv()=>match value{Some(value)=>value,None=>break},_=term.recv()=>break,_=hup.recv()=>break};
        let token = command["token"].as_str().unwrap_or("").to_owned();
        let result = match command["op"].as_str() {
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
