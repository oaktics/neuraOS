//! One readiness reactor for all PTYs. Bytes go directly to native storage.
use crate::{error::ApiError, store::StoreHandle};
use mio::{unix::SourceFd, Events, Interest, Poll, Token, Waker};
use portable_pty::{native_pty_system, CommandBuilder, MasterPty, PtySize};
use serde_json::json;
use std::{
    collections::{HashMap, HashSet, VecDeque},
    io,
    os::fd::RawFd,
    sync::{
        atomic::{AtomicBool, AtomicUsize, Ordering},
        Arc, Mutex,
    },
};
use tokio::sync::{broadcast, mpsc};
#[derive(Clone, Debug)]
pub struct PtyExit {
    pub terminal_id: String,
    pub exit_code: u32,
}
#[derive(Clone)]
enum Ownership{Local(crate::process_tree::ProcessTree),Shared(crate::process_tree::ProcessReservation)}
impl Ownership{async fn stop(&self)->Result<(),String>{match self{Self::Local(tree)=>tree.stop().await,Self::Shared(lease)=>lease.stop().await}}}
struct Session {
    owner:Ownership,
    master: Box<dyn MasterPty + Send>,
    fd: RawFd,
    pid: u32,
    token: Token,
    input: VecDeque<Vec<u8>>,
    offset: usize,
    utf8: Vec<u8>,
    pending: Option<String>,
    registered: bool,
    interest: u8,
    eof: bool,
    exit_code: Option<u32>,
}
struct Output {
    terminal_id: String,
    data: String,
    exit_code: Option<u32>,
}
struct Inner {
    supervised:bool,
    sessions: Mutex<HashMap<String, Session>>,
    tokens: Mutex<HashMap<usize, String>>,
    dirty: Mutex<HashSet<String>>,
    pressured: Mutex<HashSet<String>>,
    registry: mio::Registry,
    waker: Arc<Waker>,
    sequence: AtomicUsize,
    closed: AtomicBool,
    exits: broadcast::Sender<PtyExit>,
    store: StoreHandle,
    drained: tokio::sync::Notify,
    done: AtomicBool,
    fault: AtomicBool,
    sessions_changed: tokio::sync::Notify,
}
#[derive(Clone)]
pub struct PtyRuntime {
    inner: Arc<Inner>,
}
fn interest(s: &Session) -> Option<Interest> {
    match (s.pending.is_none() && !s.eof, !s.input.is_empty()) {
        (true, true) => Some(Interest::READABLE | Interest::WRITABLE),
        (true, false) => Some(Interest::READABLE),
        (false, true) => Some(Interest::WRITABLE),
        _ => None,
    }
}
fn register(inner: &Inner, s: &mut Session) {
    let bits = u8::from(s.pending.is_none() && !s.eof) | u8::from(!s.input.is_empty()) << 1;
    if bits == s.interest && s.registered {
        return;
    }
    s.interest = bits;
    let mut fd = SourceFd(&s.fd);
    match (interest(s), s.registered) {
        (Some(i), true) => {
            let _ = inner.registry.reregister(&mut fd, s.token, i);
        }
        (Some(i), false) => {
            s.registered = inner.registry.register(&mut fd, s.token, i).is_ok();
        }
        (None, true) => {
            let _ = inner.registry.deregister(&mut fd);
            s.registered = false;
        }
        _ => {}
    }
}
fn decode(s: &mut Session, bytes: &[u8], finish: bool) -> String {
    s.utf8.extend_from_slice(bytes);
    let mut text = String::new();
    loop {
        match std::str::from_utf8(&s.utf8) {
            Ok(v) => {
                text.push_str(v);
                s.utf8.clear();
                break;
            }
            Err(e) => {
                let valid = e.valid_up_to();
                text.push_str(std::str::from_utf8(&s.utf8[..valid]).unwrap());
                s.utf8.drain(..valid);
                if let Some(n) = e.error_len() {
                    text.push('\u{fffd}');
                    s.utf8.drain(..n);
                } else {
                    if finish {
                        text.push('\u{fffd}');
                        s.utf8.clear();
                    }
                    break;
                }
            }
        }
    }
    text
}
impl PtyRuntime {
    pub fn new(store: StoreHandle) -> Result<Self, ApiError> {Self::create(store,false)}
    pub fn new_supervised(store:StoreHandle)->Result<Self,ApiError>{Self::create(store,true)}
    fn create(store:StoreHandle,supervised:bool)->Result<Self,ApiError>{
        let mut poll = Poll::new().map_err(|_| ApiError::storage())?;
        let registry = poll
            .registry()
            .try_clone()
            .map_err(|_| ApiError::storage())?;
        let waker =
            Arc::new(Waker::new(poll.registry(), Token(0)).map_err(|_| ApiError::storage())?);
        let (exits, _) = broadcast::channel(256);
        let inner = Arc::new(Inner {
            supervised,
            sessions: Mutex::new(HashMap::new()),
            tokens: Mutex::new(HashMap::new()),
            dirty: Mutex::new(HashSet::new()),
            pressured: Mutex::new(HashSet::new()),
            registry,
            waker,
            sequence: AtomicUsize::new(1),
            closed: AtomicBool::new(false),
            exits,
            store: store.clone(),
            drained: tokio::sync::Notify::new(),
            done: AtomicBool::new(false),
            fault: AtomicBool::new(false),
            sessions_changed: tokio::sync::Notify::new(),
        });
        let (tx, mut rx) = mpsc::channel::<Output>(128);
        let io = inner.clone();
        tokio::spawn(async move {
            while let Some(first) = rx.recv().await {
                let mut rows = Vec::new();
                let mut exits = Vec::new();
                let mut bytes = 0;
                let until = tokio::time::Instant::now() + std::time::Duration::from_millis(8);
                let mut next = Some(first);
                while let Some(row) = next.take() {
                    if let Some(code) = row.exit_code {
                        exits.push((row.terminal_id, code));
                        break;
                    }
                    bytes += row.data.len();
                    rows.push(json!({"terminalId":row.terminal_id,"data":row.data}));
                    if bytes >= 256 * 1024 {
                        break;
                    }
                    next = tokio::time::timeout_at(until, rx.recv())
                        .await
                        .ok()
                        .flatten();
                }
                if !rows.is_empty() && store.call("append", json!(rows)).await.is_err() {
                    io.fault.store(true, Ordering::Release);
                    io.sessions_changed.notify_waiters();
                    io.closed.store(true, Ordering::Release);
                    let _ = io.waker.wake();
                    break;
                }
                for (id, code) in exits {
                    if store
                        .call("pty_exit", json!({"terminalId":id,"exitCode":code}))
                        .await
                        .is_err()
                    {
                        io.fault.store(true, Ordering::Release);
                        io.sessions_changed.notify_waiters();
                        continue;
                    }
                    let _ = io.exits.send(PtyExit {
                        terminal_id: id,
                        exit_code: code,
                    });
                }
                let _ = io.waker.wake();
            }
            io.done.store(true, Ordering::Release);
            io.drained.notify_waiters();
        });
        let io = inner.clone();
        std::thread::Builder::new()
            .name("native-pty-reactor".into())
            .spawn(move || {
                let mut events = Events::with_capacity(256);
                let mut ready = VecDeque::new();
                let mut scheduled = HashSet::new();
                while !io.closed.load(Ordering::Acquire) {
                    let timeout = if ready.is_empty() {
                        None
                    } else {
                        Some(std::time::Duration::ZERO)
                    };
                    if poll.poll(&mut events, timeout).is_err() {
                        break;
                    }
                    let dirty: Vec<_> = io.dirty.lock().unwrap().drain().collect();
                    let pressured: Vec<_> = io.pressured.lock().unwrap().iter().cloned().collect();
                    let mut all = io.sessions.lock().unwrap();
                    for id in dirty.into_iter().chain(pressured) {
                        if let Some(s) = all.get_mut(&id) {
                            if let Some(data) = s.pending.take() {
                                match tx.try_send(Output {
                                    terminal_id: id.clone(),
                                    data,
                                    exit_code: None,
                                }) {
                                    Ok(()) => {
                                        io.pressured.lock().unwrap().remove(&id);
                                    }
                                    Err(e) => s.pending = Some(e.into_inner().data),
                                }
                            }
                            register(&io, s);
                            if s.pending.is_none() && scheduled.insert(s.token.0) {
                                ready.push_back(s.token);
                            }
                        }
                    }
                    for event in events.iter() {
                        if event.token() != Token(0) && scheduled.insert(event.token().0) {
                            ready.push_back(event.token());
                        }
                    }
                    // Explicit ready queue preserves edge-trigger readiness while bounding each turn.
                    for _ in 0..128 {
                        let Some(token) = ready.pop_front() else {
                            break;
                        };
                        scheduled.remove(&token.0);
                        let id = io.tokens.lock().unwrap().get(&token.0).cloned();
                        let Some(id) = id else {
                            continue;
                        };
                        let Some(s) = all.get_mut(&id) else {
                            continue;
                        };
                        while let Some(input) = s.input.front() {
                            let data = &input[s.offset..];
                            let n = unsafe { libc::write(s.fd, data.as_ptr().cast(), data.len()) };
                            if n <= 0 {
                                break;
                            }
                            s.offset += n as usize;
                            if s.offset == input.len() {
                                s.input.pop_front();
                                s.offset = 0;
                            }
                        }
                        if s.pending.is_none() && !s.eof {
                            let mut bytes = [0u8; 32768];
                            let n =
                                unsafe { libc::read(s.fd, bytes.as_mut_ptr().cast(), bytes.len()) };
                            if n > 0 {
                                let data = decode(s, &bytes[..n as usize], false);
                                if !data.is_empty() {
                                    if let Err(e) = tx.try_send(Output {
                                        terminal_id: id.clone(),
                                        data,
                                        exit_code: None,
                                    }) {
                                        s.pending = Some(e.into_inner().data);
                                        io.pressured.lock().unwrap().insert(id.clone());
                                    }
                                }
                                if s.pending.is_none() && scheduled.insert(token.0) {
                                    ready.push_back(token);
                                }
                            } else if n == 0
                                || (n < 0
                                    && io::Error::last_os_error().kind()
                                        != io::ErrorKind::WouldBlock)
                            {
                                s.eof = true;
                                let tail = decode(s, &[], true);
                                if !tail.is_empty() {
                                    s.pending = Some(tail);
                                    io.pressured.lock().unwrap().insert(id.clone());
                                }
                            }
                        }
                        register(&io, s);
                        if s.eof && s.pending.is_none() && s.exit_code.is_some() {
                            if tx
                                .try_send(Output {
                                    terminal_id: id.clone(),
                                    data: String::new(),
                                    exit_code: s.exit_code,
                                })
                                .is_ok()
                            {
                                if let Some(mut s) = all.remove(&id) {
                                    s.input.clear();
                                    register(&io, &mut s);
                                }
                                io.tokens.lock().unwrap().remove(&token.0);
                                io.sessions_changed.notify_waiters();
                            } else {
                                io.dirty.lock().unwrap().insert(id);
                            }
                        }
                    }
                }
            })
            .map_err(|_| ApiError::storage())?;
        Ok(Self { inner })
    }
    pub fn subscribe_exit(&self) -> broadcast::Receiver<PtyExit> {
        self.inner.exits.subscribe()
    }
    pub fn pid(&self, id: &str) -> Option<u32> {
        self.inner.sessions.lock().unwrap().get(id).map(|s| s.pid)
    }
    pub async fn spawn(
        &self,
        id: &str,
        program: &str,
        args: Vec<String>,
        cwd: &str,
        env: HashMap<String, String>,
    ) -> Result<u32, ApiError> {
        self.check_healthy()?;
        let shared=if self.inner.supervised{Some(crate::process_tree::reserve().await.map_err(|_|ApiError::new("process_supervisor_failed","プロセス監督に接続できません。",503))?)}else{None};
        let owner_token=shared.as_ref().map(|v|v.token().to_owned()).unwrap_or_else(||uuid::Uuid::new_v4().to_string());
        let program=program.to_owned();let cwd=cwd.to_owned();let runtime=tokio::runtime::Handle::current();
        let (master,mut child,owner,pid,fd)=tokio::task::spawn_blocking(move||->Result<_,ApiError>{
          let pair=native_pty_system().openpty(PtySize{rows:30,cols:100,pixel_width:0,pixel_height:0}).map_err(|_|ApiError::new("terminal_spawn_failed","PTYを作成できません。",500))?;
          let mut command=CommandBuilder::new(program);command.args(args);command.cwd(cwd);command.env_clear();for(k,v)in env{command.env(k,v);}command.env(crate::process_tree::OWNER_ENV,&owner_token);
          let mut child=pair.slave.spawn_command(command).map_err(|_|ApiError::new("terminal_spawn_failed","CLIを起動できません。",500))?;drop(pair.slave);
          let pid=child.process_id().ok_or_else(ApiError::storage)?;
          let owner=match shared{Some(lease)=>{runtime.block_on(lease.attach(pid)).map_err(|_|ApiError::new("process_monitor_failed","CLIの所有確認に失敗しました。",500))?;Ownership::Shared(lease)},None=>match crate::process_tree::ProcessTree::new_with_token(pid,owner_token){Ok(tree)=>Ownership::Local(tree),Err(_)=>{let _=child.kill();let _=child.wait();return Err(ApiError::new("process_monitor_failed","CLIの所有確認に失敗しました。",500));}}};
          let fd=pair.master.as_raw_fd().ok_or_else(ApiError::storage)?;unsafe{libc::fcntl(fd,libc::F_SETFL,libc::fcntl(fd,libc::F_GETFL)|libc::O_NONBLOCK);}
          Ok((pair.master,child,owner,pid,fd))
        }).await.map_err(|_|ApiError::storage())??;
        let token = Token(self.inner.sequence.fetch_add(1, Ordering::Relaxed));
        let mut session = Session {
            master,
            owner:owner.clone(),
            fd,
            pid,
            token,
            input: VecDeque::new(),
            offset: 0,
            utf8: Vec::new(),
            pending: None,
            registered: false,
            interest: 0,
            eof: false,
            exit_code: None,
        };
        register(&self.inner, &mut session);
        self.inner
            .sessions
            .lock()
            .unwrap()
            .insert(id.into(), session);
        self.inner.tokens.lock().unwrap().insert(token.0, id.into());
        self.inner.dirty.lock().unwrap().insert(id.into());
        let _ = self.inner.waker.wake();
        let inner = self.inner.clone();
        let terminal_id = id.to_owned();
        let runtime=tokio::runtime::Handle::current();
        std::thread::Builder::new()
            .name("native-pty-exit".into())
            .stack_size(128 * 1024)
            .spawn(move || {
                let code = child.wait().map(|s| s.exit_code()).unwrap_or(1);
                if runtime.block_on(owner.stop()).is_err(){inner.fault.store(true,Ordering::Release);inner.sessions_changed.notify_waiters();}
                if let Some(s) = inner.sessions.lock().unwrap().get_mut(&terminal_id) {
                    s.exit_code = Some(code);
                }
                inner.dirty.lock().unwrap().insert(terminal_id);
                let _ = inner.waker.wake();
            })
            .map_err(|_| ApiError::storage())?;
        Ok(pid)
    }
    pub async fn input(&self, id: &str, data: &str) -> Result<(), ApiError> {
        self.check_healthy()?;
        let mut all = self.inner.sessions.lock().unwrap();
        let s = all.get_mut(id).ok_or_else(|| {
            ApiError::new("terminal_stopped", "ターミナルは停止しています。", 409)
        })?;
        let pending: usize = s.input.iter().map(Vec::len).sum();
        if pending + data.len() > 1024 * 1024 {
            return Err(ApiError::new(
                "terminal_busy",
                "入力処理の空きを待ってください。",
                409,
            ));
        }
        s.input.push_back(data.as_bytes().to_vec());
        self.inner.dirty.lock().unwrap().insert(id.into());
        register(&self.inner, s);
        let _ = self.inner.waker.wake();
        Ok(())
    }
    pub async fn resize(&self, id: &str, cols: u16, rows: u16) -> Result<(), ApiError> {
        self.check_healthy()?;
        if self.pid(id).is_none() {
            return Err(ApiError::new(
                "terminal_stopped",
                "ターミナルは停止しています。",
                409,
            ));
        }
        self.inner
            .store
            .call(
                "append",
                json!([{"terminalId":id,"data":"","cols":cols,"rows":rows}]),
            )
            .await?;
        let all = self.inner.sessions.lock().unwrap();
        all.get(id)
            .ok_or_else(|| ApiError::new("terminal_stopped", "ターミナルは停止しています。", 409))?
            .master
            .resize(PtySize {
                rows,
                cols,
                pixel_width: 0,
                pixel_height: 0,
            })
            .map_err(|_| ApiError::storage())?;
        Ok(())
    }
    pub async fn stop(&self,id:&str)->Result<(),ApiError>{
      let owner=self.inner.sessions.lock().unwrap().get(id).map(|s|s.owner.clone());
      if let Some(owner)=owner{owner.stop().await.map_err(|_|ApiError::new("process_cleanup_failed","CLI子孫の終了を確認できません。",500))?;}Ok(())
    }
    pub fn check_healthy(&self)->Result<(),ApiError>{if self.inner.fault.load(Ordering::Acquire){return Err(ApiError::new("terminal_runtime_failed","PTY保存または所有プロセスの処理に失敗しました。",503));}if self.inner.closed.load(Ordering::Acquire){return Err(ApiError::new("terminal_runtime_closed","PTYは終了処理中です。",503));}Ok(())}
    pub async fn shutdown(&self) -> Result<(), ApiError> {
        let ids: Vec<_> = self
            .inner
            .sessions
            .lock()
            .unwrap()
            .keys()
            .cloned()
            .collect();
        let results=futures_util::future::join_all(ids.iter().map(|id|self.stop(id))).await;
        let stop_failed=results.iter().any(Result::is_err);
        let drain = async {
            loop {
                let changed = self.inner.sessions_changed.notified();
                tokio::pin!(changed);
                changed.as_mut().enable();
                if self.inner.fault.load(Ordering::Acquire) {
                    return Err(ApiError::storage());
                }
                if self.inner.sessions.lock().unwrap().is_empty() {
                    break;
                }
                changed.await;
            }
            // Session removal happens only after EOF, UTF8 carry and the exit marker have
            // entered the FIFO output queue. Closing the reactor now drops its sender;
            // the storage consumer then drains every accepted byte before reporting done.
            self.inner.closed.store(true, Ordering::Release);
            let _ = self.inner.waker.wake();
            let drained = self.inner.drained.notified();
            tokio::pin!(drained);
            drained.as_mut().enable();
            if !self.inner.done.load(Ordering::Acquire) {
                drained.await;
            }
            if self.inner.fault.load(Ordering::Acquire) {
                return Err(ApiError::storage());
            }
            self.inner.store.call("barrier", json!({})).await?;
            Ok(())
        };
        let drained=tokio::time::timeout(std::time::Duration::from_secs(15), drain)
            .await
            .map_err(|_| {
                ApiError::new(
                    "terminal_drain_timeout",
                    "PTYの保存完了を確認できません。",
                    500,
                )
            })?;
        if stop_failed{return Err(ApiError::new("process_cleanup_failed","CLI子孫の終了を確認できません。",500));}drained
    }
}
