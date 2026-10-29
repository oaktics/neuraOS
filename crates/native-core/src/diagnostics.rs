//! Bounded diagnostic log writer. No paths, request payloads or error text enter
//! exported rows. Filesystem work never runs on the HTTP/PTY executor.
use serde_json::{json, Value};
use std::{
    fs::{self, OpenOptions},
    io::Write,
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    path::PathBuf,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc,
    },
};
use tokio::sync::{mpsc, oneshot};
#[derive(Clone, Copy)]
pub enum Phase {
    Received,
    Executing,
    Success,
    Failure,
    Start,
    End,
}
impl Phase {
    fn name(self) -> &'static str {
        match self {
            Self::Received => "operation.received",
            Self::Executing => "operation.executing",
            Self::Success => "operation.success",
            Self::Failure => "operation.failure",
            Self::Start => "daemon.start",
            Self::End => "daemon.end",
        }
    }
}
enum Entry {
    Row(Value),
    Flush(oneshot::Sender<()>),
}
#[derive(Clone)]
pub struct Diagnostics {
    sender: mpsc::Sender<Entry>,
    dropped: Arc<AtomicU64>,
    session: String,
}
impl Diagnostics {
    pub fn new(directory: PathBuf) -> std::io::Result<Self> {
        Self::with_limit(directory, 1_048_576)
    }
    fn with_limit(directory: PathBuf, limit: u64) -> std::io::Result<Self> {
        let (sender, mut receiver) = mpsc::channel(256);
        let dropped = Arc::new(AtomicU64::new(0));
        let missed = dropped.clone();
        std::thread::Builder::new()
            .name("native-diagnostics".into())
            .spawn(move || {
                while let Some(entry) = receiver.blocking_recv() {
                    match entry {
                        Entry::Row(mut row) => {
                            let count = missed.swap(0, Ordering::Relaxed);
                            if count > 0 {
                                row["droppedEvents"] = json!(count);
                            }
                            if append(&directory, limit, &row).is_err() {
                                missed.fetch_add(count.saturating_add(1), Ordering::Relaxed);
                            }
                        }
                        Entry::Flush(done) => {
                            let _ = done.send(());
                        }
                    }
                }
            })?;
        Ok(Self {
            sender,
            dropped,
            session: uuid::Uuid::new_v4().to_string(),
        })
    }
    pub fn record(
        &self,
        phase: Phase,
        operation: Option<&str>,
        operation_id: Option<&str>,
        duration_ms: Option<f64>,
    ) {
        let mut row = json!({"time":chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis,true),"session":self.session,"runtime":"rust","event":phase.name()});
        // Fields identify known commands and correlation only; omit arbitrary strings.
        if let Some(op) = operation.filter(|s| {
            s.len() <= 64
                && s.bytes()
                    .all(|b| b.is_ascii_lowercase() || b == b'.' || b == b'-')
        }) {
            row["operation"] = json!(op);
        }
        if let Some(id) = operation_id.filter(|id| crate::contracts::valid_uuid(id)) {
            row["operationId"] = json!(id);
        }
        if let Some(ms) = duration_ms.filter(|ms| ms.is_finite() && *ms >= 0.) {
            row["durationMs"] = json!(ms);
        }
        if self.sender.try_send(Entry::Row(row)).is_err() {
            self.dropped.fetch_add(1, Ordering::Relaxed);
        }
    }
    pub async fn flush(&self) {
        let (tx, rx) = oneshot::channel();
        let _ = tokio::time::timeout(std::time::Duration::from_secs(2), async {
            if self.sender.send(Entry::Flush(tx)).await.is_ok() {
                let _ = rx.await;
            }
        })
        .await;
    }
}
fn append(directory: &std::path::Path, limit: u64, row: &Value) -> std::io::Result<()> {
    fs::create_dir_all(directory)?;
    if fs::symlink_metadata(directory)?.file_type().is_symlink() {
        return Err(std::io::Error::other(
            "diagnostics directory must not be a symlink",
        ));
    }
    fs::set_permissions(directory, fs::Permissions::from_mode(0o700))?;
    let file = directory.join("daemon.jsonl");
    let previous = directory.join("daemon.previous.jsonl");
    if let Ok(meta) = fs::symlink_metadata(&file) {
        if !meta.is_file() || meta.file_type().is_symlink() {
            return Err(std::io::Error::other(
                "diagnostic log must be a regular file",
            ));
        }
        if meta.len() >= limit {
            match fs::remove_file(&previous) {
                Ok(()) => {}
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                Err(e) => return Err(e),
            }
            fs::rename(&file, &previous)?;
        }
    }
    let mut writer = OpenOptions::new()
        .append(true)
        .create(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(file)?;
    writer.set_permissions(fs::Permissions::from_mode(0o600))?;
    let mut bytes = serde_json::to_vec(row)?;
    bytes.push(b'\n');
    writer.write_all(&bytes)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn exports_only_correlation_fields_and_rotates_private_logs() {
        let dir = std::env::temp_dir().join(format!("neura-diagnostics-{}", uuid::Uuid::new_v4()));
        let d = Diagnostics::with_limit(dir.clone(), 300).unwrap();
        let id = uuid::Uuid::new_v4().to_string();
        for _ in 0..8 {
            d.record(Phase::Success, Some("terminal.input"), Some(&id), Some(10.));
        }
        d.record(
            Phase::Failure,
            Some("/private/password=secret"),
            Some("token=secret"),
            Some(f64::NAN),
        );
        d.flush().await;
        let current = fs::read_to_string(dir.join("daemon.jsonl")).unwrap();
        let previous = fs::read_to_string(dir.join("daemon.previous.jsonl")).unwrap();
        assert!(!current.contains("secret"));
        assert!(!previous.contains("secret"));
        for path in ["daemon.jsonl", "daemon.previous.jsonl"] {
            assert_eq!(
                fs::metadata(dir.join(path)).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
        let last: Value = serde_json::from_str(current.lines().last().unwrap()).unwrap();
        assert_eq!(last["event"], "operation.failure");
        assert!(last.get("operation").is_none());
        assert!(last.get("durationMs").is_none());
        drop(d);
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn refuses_symlink_log_without_touching_target() {
        let dir = std::env::temp_dir().join(format!("neura-diagnostics-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&dir).unwrap();
        let target = dir.join("private");
        fs::write(&target, "unchanged").unwrap();
        std::os::unix::fs::symlink(&target, dir.join("daemon.jsonl")).unwrap();
        assert!(append(&dir, 1024, &json!({"event":"daemon.start"})).is_err());
        assert_eq!(fs::read_to_string(target).unwrap(), "unchanged");
        fs::remove_dir_all(dir).unwrap();
    }
}
