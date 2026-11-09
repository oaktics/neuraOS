//! Durable, resumable worktree deletion. Only the approved inode is destroyed.
use super::{delete_step, text, verify_delete, ApiError, AppState, Phase};
use neura_native_core::{mutation, workspace as work};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::os::unix::{
    fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
    io::{AsRawFd, FromRawFd, RawFd},
};
use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};
use tokio::sync::{Mutex, Notify};

#[derive(Default)]
pub(super) struct Manager {
    tasks: Mutex<HashMap<String, tokio::task::JoinHandle<()>>>,
    signals: Mutex<HashMap<String, std::sync::Weak<Notify>>>,
    #[cfg(test)]
    pauses: Mutex<HashMap<String, (Arc<Notify>, Arc<Notify>)>>,
}
async fn pulse(s: &AppState, id: &str) -> Arc<Notify> {
    let mut signals = s.deletions.signals.lock().await;
    signals.retain(|_, v| v.strong_count() > 0);
    if let Some(signal) = signals.get(id).and_then(std::sync::Weak::upgrade) {
        return signal;
    }
    let signal = Arc::new(Notify::new());
    signals.insert(id.into(), Arc::downgrade(&signal));
    signal
}
async fn signal(s: &AppState, id: &str) {
    if let Some(signal) = s
        .deletions
        .signals
        .lock()
        .await
        .get(id)
        .and_then(std::sync::Weak::upgrade)
    {
        signal.notify_waiters();
    }
}
fn failure(code: &str) -> ApiError {
    ApiError::new(
        code,
        match code {
            "workspace_deleting" => "作業領域を削除中です。",
            "deletion_identity_changed" => "削除対象の同一性を確認できません。対象を保持します。",
            "deletion_missing" => "削除ジョブがありません。",
            "deletion_cancelled" => "削除は再起動後に再開します。",
            _ => "削除ジョブを確認してください。",
        },
        409,
    )
}
fn checked(value: Value) -> Result<Value, ApiError> {
    if let Some(code) = value["error"].as_str() {
        Err(failure(code))
    } else {
        Ok(value)
    }
}
pub(super) fn public(job: &Value) -> Value {
    let mut value = job["public"].clone();
    if value["error"].is_null() {
        value.as_object_mut().map(|v| v.remove("error"));
    }
    value
}
async fn load(s: &AppState, id: &str) -> Result<Value, ApiError> {
    let job = s
        .store
        .call("workspace_deletion_get", json!({"id":id}))
        .await?;
    if job.is_null() {
        Err(failure("deletion_missing"))
    } else {
        Ok(job)
    }
}
async fn update(s: &AppState, job: &mut Value, patch: Value) -> Result<(), ApiError> {
    *job = checked(
        s.store
            .call(
                "workspace_deletion_update",
                json!({"id":job["id"],"revision":job["public"]["revision"],"patch":patch}),
            )
            .await?,
    )?;
    signal(s, text(job, "id")?).await;
    Ok(())
}
async fn phase(s: &AppState, job: &mut Value, name: &str) -> Result<(), ApiError> {
    update(
        s,
        job,
        json!({"public":{"status":"running","phase":name,"error":null}}),
    )
    .await
}
pub(super) async fn gate(s: &AppState, id: &str) -> Result<(), ApiError> {
    let value = s
        .store
        .call("workspace_deletion_gate", json!({"workspaceId":id}))
        .await?;
    if value["blocked"] == true {
        return Err(failure("workspace_deleting"));
    }
    Ok(())
}
pub(super) async fn project_gate(s: &AppState, project: &str) -> Result<(), ApiError> {
    for w in s.store.list("workspaces").await? {
        if w["projectId"] == project {
            gate(s, text(&w, "id")?).await?;
        }
    }
    Ok(())
}
async fn accept(
    s: &AppState,
    op: &str,
    c: &Value,
    canonical: &Value,
    hash: &str,
) -> Result<Value, ApiError> {
    let retry = c["type"] == "workspace.deletion.retry";
    let workspace = if retry {
        load(&s, text(c, "jobId")?).await?["public"]["workspaceId"]
            .as_str()
            .ok_or_else(ApiError::storage)?
            .to_owned()
    } else {
        text(c, "workspaceId")?.to_owned()
    };
    // Fast rejection is NOT the fence: writer admission below drains active
    // provider/open leases before publishing the durable workspace gate.
    let w = s.store.get("workspaces", &workspace).await?;
    let project = w.as_ref().and_then(|w| w["projectId"].as_str());
    let _scope = s
        .mutation
        .enter(project, Some(&workspace), false, false)
        .await;
    let _admission = mutation::workspace_deletion_admission(&workspace).await;
    if s.setups.lock().await.contains_key(&workspace) {
        return Err(failure("setup_running"));
    }
    if *s.closing.borrow() {
        return Err(failure("deletion_cancelled"));
    }
    let job = checked(
        s.store
            .call(
                if retry {
                    "workspace_deletion_retry"
                } else {
                    "workspace_deletion_accept"
                },
                json!({"operationId":op,"hash":hash,"command":canonical,"jobId":c["jobId"]}),
            )
            .await?,
    )?;
    Ok(job)
}
pub(super) async fn command(s: Arc<AppState>, op: &str, c: &Value) -> Result<Value, ApiError> {
    let admission_started = std::time::Instant::now();
    let retry = c["type"] == "workspace.deletion.retry";
    let mut canonical = c.clone();
    if !retry {
        canonical["type"] = json!("workspace.delete");
    }
    let hash = work::hash(&canonical.to_string());
    // Same-operation serialization includes prechecks and durable rejection, but
    // ends before legacy completion waiting so replays remain responsive.
    let lock = {
        let mut locks = s.operations.lock().await;
        locks.retain(|_, v| v.strong_count() > 0);
        if let Some(lock) = locks.get(op).and_then(std::sync::Weak::upgrade) {
            lock
        } else {
            let lock = Arc::new(Mutex::new(()));
            locks.insert(op.to_owned(), Arc::downgrade(&lock));
            lock
        }
    };
    let guard = lock.lock().await;
    // Replay before mutable workspace/setup checks, including after workspace removal.
    let prior = checked(
        s.store
            .call(
                "workspace_deletion_operation",
                json!({"operationId":op,"hash":hash}),
            )
            .await?,
    )?;
    let job = if !prior.is_null() {
        prior
    } else {
        match accept(&s,op,c,&canonical,&hash).await {
            Ok(job)=>job,
            Err(error) if !["storage_failed","deletion_cancelled","operation_conflict","operation_unknown"].contains(&error.error.as_str()) => {
                checked(s.store.call("workspace_deletion_reject",json!({"operationId":op,"hash":hash,"rejection":{"code":error.error,"message":error.message,"status":error.status}})).await?)?
            }
            Err(error)=>return Err(error),
        }
    };
    drop(guard);
    if let Some(rejected) = job.get("deletionRejected") {
        let mut error = ApiError::new(
            rejected["code"].as_str().unwrap_or("deletion_failed"),
            rejected["message"]
                .as_str()
                .unwrap_or("削除に失敗しました。"),
            rejected["status"].as_u64().unwrap_or(409) as u16,
        );
        error.operation_id = Some(op.to_owned());
        error.operation_final = Some(true);
        return Err(error);
    }
    s.diagnostics.record(
        Phase::DeleteAdmission,
        c["type"].as_str(),
        Some(op),
        Some(admission_started.elapsed().as_secs_f64() * 1000.0),
    );
    if job.get("legacyOperation").is_some() {
        if c["type"] != "workspace.delete" {
            return Err(failure("operation_unknown"));
        }
        if job["legacyOperation"] == "done" {
            return Ok(job["legacyResult"].clone());
        }
        let prior = &job["legacyResult"];
        let mut error = ApiError::new(
            prior["code"].as_str().unwrap_or("deletion_failed"),
            prior["message"].as_str().unwrap_or("削除に失敗しました。"),
            prior["status"].as_u64().unwrap_or(409) as u16,
        );
        // Historical terminal failure is also definitive for this exact legacy
        // operation, even when its workspace has since disappeared.
        error.operation_id = Some(op.to_owned());
        error.operation_final = Some(true);
        return Err(error);
    }
    let id = text(&job, "id")?.to_owned();
    signal(&s, &id).await;
    spawn(s.clone(), &id).await;
    if c["type"] == "workspace.delete" {
        let pulse = pulse(&s, &id).await;
        let mut closing = s.closing.subscribe();
        loop {
            let notified = pulse.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            let job = load(&s, &id).await?;
            match job["public"]["status"].as_str() {
                Some("succeeded") => return Ok(json!({"ok":true})),
                Some("failed") => {
                    return Err(ApiError::new(
                        job["public"]["error"]["code"]
                            .as_str()
                            .unwrap_or("deletion_failed"),
                        job["public"]["error"]["message"]
                            .as_str()
                            .unwrap_or("削除に失敗しました。"),
                        409,
                    ))
                }
                _ => {}
            }
            if *s.closing.borrow() {
                return Err(failure("deletion_cancelled"));
            }
            tokio::select! {_=notified=>{},_=closing.changed()=>{}}
        }
    }
    Ok(json!({"ok":true,"accepted":true,"job":public(&job)}))
}
pub(super) async fn read(
    s: Arc<AppState>,
    id: String,
    query: HashMap<String, String>,
) -> Result<Value, ApiError> {
    super::id(&id)?;
    let parse = |key: &str| -> Result<Option<u64>, ApiError> {
        query
            .get(key)
            .map(|v| v.parse::<u64>().map_err(|_| super::invalid()))
            .transpose()
    };
    let wait = parse("waitMs")?.unwrap_or(0);
    if wait > 25000 {
        return Err(super::invalid());
    }
    let mut after = parse("afterRevision")?;
    let pulse = pulse(&s, &id).await;
    let mut closing = s.closing.subscribe();
    let deadline = tokio::time::Instant::now() + Duration::from_millis(wait);
    loop {
        let notified = pulse.notified();
        tokio::pin!(notified);
        notified.as_mut().enable();
        let job = load(&s, &id).await?;
        if after.is_none() {
            after = job["public"]["revision"].as_u64();
        }
        if wait == 0
            || ["succeeded", "failed"].contains(&job["public"]["status"].as_str().unwrap_or(""))
            || after.is_none_or(|n| job["public"]["revision"].as_u64() != Some(n))
            || tokio::time::Instant::now() >= deadline
        {
            return Ok(public(&job));
        }
        if *closing.borrow() {
            return Err(failure("deletion_cancelled"));
        }
        tokio::select! {_=notified=>{},_=tokio::time::sleep_until(deadline)=>{},_=closing.changed()=>{}}
    }
}
pub(super) async fn recover(s: Arc<AppState>) -> Result<(), ApiError> {
    for job in s
        .store
        .call("workspace_deletion_list", json!({}))
        .await?
        .as_array()
        .ok_or_else(ApiError::storage)?
    {
        if ["queued", "running"].contains(&job["public"]["status"].as_str().unwrap_or("")) {
            spawn(s.clone(), text(job, "id")?).await;
        }
    }
    Ok(())
}
async fn spawn(s: Arc<AppState>, id: &str) {
    let mut tasks = s.deletions.tasks.lock().await;
    tasks.retain(|_, task| !task.is_finished());
    if tasks.get(id).is_some_and(|t| !t.is_finished()) {
        return;
    }
    let owner = s.clone();
    let id = id.to_owned();
    tasks.insert(id.clone(), tokio::spawn(async move {
        loop {
            if let Ok(mut job) = load(&owner, &id).await {
                if ["queued","running"].contains(&job["public"]["status"].as_str().unwrap_or("")) {
                    if let Err(error) = run(&owner, &mut job).await {
                        if error.error != "deletion_cancelled" {
                            let blocks = irreversible(&job);
                            let retryable = error.error != "deletion_identity_changed";
                            // Git stderr can contain private quarantine/admin paths.
                            let message=if ["git_failed","operation_failed"].contains(&error.error.as_str()) {"Git処理に失敗しました。削除ジョブを確認してください。".to_owned()}else{error.message};
                            let _ = update(&owner, &mut job, json!({"public":{"status":"failed","blocksWorkspace":blocks,"retryable":retryable,"error":{"code":error.error,"message":message}}})).await;
                        }
                    }
                }
            }
            // Serialize task retirement against retry's spawn. A retry may have
            // committed queued just after this worker published its failure.
            let mut tasks=owner.deletions.tasks.lock().await;
            let retry=load(&owner,&id).await.is_ok_and(|j|j["public"]["status"]=="queued");
            if retry && !*owner.closing.borrow(){drop(tasks);continue;}
            tasks.remove(&id);
            break;
        }
    }));
}

pub(super) async fn shutdown(s: &AppState) {
    let tasks: Vec<_> = s
        .deletions
        .tasks
        .lock()
        .await
        .drain()
        .map(|(_, t)| t)
        .collect();
    for task in tasks {
        let _ = task.await;
    }
}
fn cancelled(s: &AppState) -> Result<(), ApiError> {
    if *s.closing.borrow() {
        Err(failure("deletion_cancelled"))
    } else {
        Ok(())
    }
}
#[derive(Clone, Serialize, Deserialize, PartialEq, Debug)]
struct Identity {
    dev: u64,
    ino: u64,
}
impl Identity {
    fn of(meta: &std::fs::Metadata) -> Self {
        Self {
            dev: meta.dev(),
            ino: meta.ino(),
        }
    }
    fn at(path: &Path) -> Result<Option<Self>, ApiError> {
        match std::fs::symlink_metadata(path) {
            Ok(m) if m.is_dir() && !m.file_type().is_symlink() => Ok(Some(Self::of(&m))),
            Ok(_) => Err(failure("deletion_identity_changed")),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(_) => Err(failure("deletion_filesystem_failed")),
        }
    }
    fn matches(&self, path: &Path) -> Result<(), ApiError> {
        if Self::at(path)?.as_ref() == Some(self) {
            Ok(())
        } else {
            Err(failure("deletion_identity_changed"))
        }
    }
}
#[derive(Clone, Serialize, Deserialize)]
struct Fence {
    source: PathBuf,
    target: PathBuf,
    parent: PathBuf,
    root: Identity,
    parent_id: Identity,
    admin: PathBuf,
    admin_id: Identity,
    common: PathBuf,
    common_id: Identity,
    head: String,
    project: String,
}
fn fence(job: &Value) -> Result<Fence, ApiError> {
    serde_json::from_value(job["fence"].clone()).map_err(|_| failure("deletion_identity_changed"))
}
fn irreversible(job: &Value) -> bool {
    if job["fence"].is_null() {
        return false;
    }
    let Ok(f) = fence(job) else {
        return true;
    };
    // Only a positively unchanged source, absent destination and pre-removal
    // phase can safely release the workspace for a new user-authorized attempt.
    !matches!(Identity::at(&f.source),Ok(Some(ref id)) if id==&f.root)
        || !matches!(Identity::at(&f.target), Ok(None))
        || job["removalStarted"] == true
}
fn fs_sync(path: &Path) -> Result<(), ApiError> {
    std::fs::File::open(path)
        .and_then(|f| f.sync_all())
        .map_err(|_| failure("deletion_filesystem_failed"))
}
async fn capture(s: &AppState, job: &Value) -> Result<Fence, ApiError> {
    let w = &job["workspace"];
    let supplied = PathBuf::from(text(w, "path")?);
    let original = Identity::at(&supplied)?.ok_or_else(|| failure("deletion_identity_changed"))?;
    let source =
        std::fs::canonicalize(&supplied).map_err(|_| failure("deletion_identity_changed"))?;
    original.matches(&source)?;
    let parent = source
        .parent()
        .ok_or_else(|| failure("deletion_identity_changed"))?
        .to_path_buf();
    let root = Identity::at(&source)?.ok_or_else(|| failure("deletion_identity_changed"))?;
    let parent_id = Identity::at(&parent)?.ok_or_else(|| failure("deletion_identity_changed"))?;
    // Resolve existing ancestors once; recorded paths must not alias via symlinks.
    if std::fs::canonicalize(&source).map_err(|_| failure("deletion_identity_changed"))? != source {
        return Err(failure("deletion_identity_changed"));
    }
    let target = parent.join(format!(".neura-delete-{}", text(job, "id")?));
    if Identity::at(&target)?.is_some() {
        return Err(failure("deletion_identity_changed"));
    }
    let path = source.to_str().ok_or_else(ApiError::storage)?;
    let admin = PathBuf::from(
        work::git(path, &["rev-parse", "--absolute-git-dir"])
            .await?
            .trim(),
    );
    let common = PathBuf::from(
        work::git(
            path,
            &["rev-parse", "--path-format=absolute", "--git-common-dir"],
        )
        .await?
        .trim(),
    );
    let admin = std::fs::canonicalize(admin).map_err(|_| failure("deletion_identity_changed"))?;
    let common = std::fs::canonicalize(common).map_err(|_| failure("deletion_identity_changed"))?;
    if admin == common || admin.parent() != Some(common.join("worktrees").as_path()) {
        return Err(failure("deletion_identity_changed"));
    }
    let p = s.entity("projects", text(w, "projectId")?).await?;
    Ok(Fence {
        admin_id: Identity::at(&admin)?.ok_or_else(ApiError::storage)?,
        common_id: Identity::at(&common)?.ok_or_else(ApiError::storage)?,
        head: work::git(path, &["rev-parse", "HEAD"]).await?.trim().into(),
        project: text(&p, "path")?.into(),
        source,
        target,
        parent,
        root,
        parent_id,
        admin,
        common,
    })
}
fn path_text(path: &Path) -> Result<&str, ApiError> {
    path.to_str().ok_or_else(ApiError::storage)
}
async fn metadata(f: &Fence, allow_absent: bool) -> Result<bool, ApiError> {
    f.parent_id.matches(&f.parent)?;
    f.common_id.matches(&f.common)?;
    for path in [&f.parent, &f.common] {
        if std::fs::canonicalize(path).map_err(|_| failure("deletion_identity_changed"))? != *path {
            return Err(failure("deletion_identity_changed"));
        }
    }
    match Identity::at(&f.admin)? {
        None if allow_absent => return Ok(false),
        Some(id) if id == f.admin_id => {}
        _ => return Err(failure("deletion_identity_changed")),
    }
    if std::fs::canonicalize(&f.admin).map_err(|_| failure("deletion_identity_changed"))? != f.admin
    {
        return Err(failure("deletion_identity_changed"));
    }
    let common_link = std::fs::read_to_string(f.admin.join("commondir"))
        .map_err(|_| failure("deletion_identity_changed"))?;
    if std::fs::canonicalize(f.admin.join(common_link.trim()))
        .map_err(|_| failure("deletion_identity_changed"))?
        != f.common
    {
        return Err(failure("deletion_identity_changed"));
    }
    let head = work::git(
        path_text(&f.parent)?,
        &["--git-dir", path_text(&f.admin)?, "rev-parse", "HEAD"],
    )
    .await?;
    if head.trim() != f.head {
        return Err(failure("deletion_identity_changed"));
    }
    Ok(true)
}
async fn repo_git(f: &Fence, args: &[&str]) -> Result<String, ApiError> {
    f.parent_id.matches(&f.parent)?;
    f.common_id.matches(&f.common)?;
    if std::fs::canonicalize(&f.common).map_err(|_| failure("deletion_identity_changed"))?
        != f.common
    {
        return Err(failure("deletion_identity_changed"));
    }
    let mut command = vec!["--git-dir", path_text(&f.common)?];
    command.extend_from_slice(args);
    work::git(path_text(&f.parent)?, &command).await
}
fn link_matches(f: &Fence, root: &Path) -> bool {
    std::fs::read_to_string(root.join(".git"))
        .is_ok_and(|v| v.trim() == format!("gitdir: {}", f.admin.display()))
        && std::fs::read_to_string(f.admin.join("gitdir"))
            .is_ok_and(|v| v.trim() == root.join(".git").to_string_lossy())
}
async fn run(s: &AppState, job: &mut Value) -> Result<(), ApiError> {
    cancelled(s)?;
    #[cfg(test)]
    pause_point(s, text(job, "id")?).await?;
    let fresh = job["fence"].is_null();
    if fresh {
        phase(s, job, "verify-before").await?;
        let w = job["workspace"].clone();
        let c = job["command"].clone();
        delete_step(
            s,
            text(job, "id")?,
            Phase::DeleteVerifyBefore,
            verify_delete(s, &w, &c),
        )
        .await?;
        if c["stopTerminals"] != true
            && s.store
                .list("terminals")
                .await?
                .iter()
                .any(|t| t["workspaceId"] == w["id"] && t["status"] == "running")
        {
            return Err(failure("workspace_running"));
        }
        if c["stopTerminals"] == true {
            phase(s, job, "stop-terminals").await?;
            delete_step(
                s,
                text(job, "id")?,
                Phase::DeleteStopTerminals,
                s.stop_workspace(text(&w, "id")?),
            )
            .await?;
        }
        phase(s, job, "verify-after").await?;
        delete_step(
            s,
            text(job, "id")?,
            Phase::DeleteVerifyAfter,
            verify_delete(s, &w, &c),
        )
        .await?;
        cancelled(s)?;
        let f = capture(s, job).await?;
        update(
            s,
            job,
            json!({"fence":f,"public":{"status":"running","phase":"isolate"}}),
        )
        .await?;
    }
    let f = fence(job)?;
    cancelled(s)?;
    // Only resume partial destruction after the durable remove-files intent.
    if job["removalStarted"] != true {
        metadata(&f, false).await?;
        let src = Identity::at(&f.source)?;
        let dst = Identity::at(&f.target)?;
        match (src, dst) {
            (Some(ref id), None) if id == &f.root => {
                if !link_matches(&f, &f.source) {
                    return Err(failure("deletion_identity_changed"));
                }
                // Only restart recovery repeats pre/post checks; a fresh capture
                // already followed this run's complete verification and stop.
                if !fresh {
                    let w = job["workspace"].clone();
                    let c = job["command"].clone();
                    verify_delete(s, &w, &c).await?;
                    s.stop_workspace(text(&w, "id")?).await?;
                    verify_delete(s, &w, &c).await?;
                }
                cancelled(s)?;
                repo_git(
                    &f,
                    &[
                        "worktree",
                        "move",
                        "--",
                        path_text(&f.source)?,
                        path_text(&f.target)?,
                    ],
                )
                .await?;
            }
            (None, Some(ref id)) if id == &f.root => {}
            _ => return Err(failure("deletion_identity_changed")),
        }
        f.root.matches(&f.target)?;
        if Identity::at(&f.source)?.is_some() {
            return Err(failure("deletion_identity_changed"));
        }
        if !link_matches(&f, &f.target) {
            // Git may have renamed the directory before updating its backpointer.
            // Repair only this positively identified worktree, never global prune.
            repo_git(&f, &["worktree", "repair", "--", path_text(&f.target)?]).await?;
            if !link_matches(&f, &f.target) {
                return Err(failure("deletion_identity_changed"));
            }
        }
        metadata(&f, false).await?;
        std::fs::set_permissions(&f.target, std::fs::Permissions::from_mode(0o700))
            .map_err(|_| failure("deletion_filesystem_failed"))?;
        fs_sync(&f.target)?;
        fs_sync(&f.parent)?;
        update(
            s,
            job,
            json!({"removalStarted":true,"public":{"status":"running","phase":"remove-files"}}),
        )
        .await?;
    }
    #[cfg(test)]
    pause_point(s, &format!("{}:remove-files", text(job, "id")?)).await?;
    cancelled(s)?;
    if Identity::at(&f.source)?.is_some() {
        return Err(failure("deletion_identity_changed"));
    }
    let admin_exists = metadata(&f, true).await?;
    if let Some(id) = Identity::at(&f.target)? {
        if id != f.root || !admin_exists {
            return Err(failure("deletion_identity_changed"));
        }
        let copy = f.clone();
        let closing = s.closing.clone();
        tokio::task::spawn_blocking(move || remove_fenced(&copy, || *closing.borrow()))
            .await
            .map_err(|_| failure("deletion_filesystem_failed"))??;
    }
    cancelled(s)?;
    if Identity::at(&f.source)?.is_some() || Identity::at(&f.target)?.is_some() {
        return Err(failure("deletion_identity_changed"));
    }
    phase(s, job, "remove-git").await?;
    if metadata(&f, true).await? {
        // The retained admin backpointer must still name precisely our target.
        if !std::fs::read_to_string(f.admin.join("gitdir"))
            .is_ok_and(|v| v.trim() == f.target.join(".git").to_string_lossy())
        {
            return Err(failure("deletion_identity_changed"));
        }
        delete_step(
            s,
            text(job, "id")?,
            Phase::DeleteGitRemove,
            repo_git(&f, &["worktree", "remove", "--", path_text(&f.target)?]),
        )
        .await?;
    }
    // Independently check registration and both paths, then atomically retire
    // workspace/terminals/output and mark the durable job succeeded.
    let list = repo_git(&f, &["worktree", "list", "--porcelain", "-z"]).await?;
    for item in list.split('\0') {
        if item
            .strip_prefix("worktree ")
            .is_some_and(|p| p == f.source.to_string_lossy() || p == f.target.to_string_lossy())
        {
            return Err(failure("deletion_git_registration_remains"));
        }
    }
    if Identity::at(&f.admin)?.is_some()
        || Identity::at(&f.source)?.is_some()
        || Identity::at(&f.target)?.is_some()
    {
        return Err(failure("deletion_identity_changed"));
    }
    phase(s, job, "finalize").await?;
    loop {
        cancelled(s)?;
        let batch = checked(
            s.store
                .call("workspace_deletion_purge", json!({"id":job["id"]}))
                .await?,
        )?;
        if batch["done"] == true {
            break;
        }
        tokio::task::yield_now().await;
    }
    // Filesystem replacements during the bounded purge must not become success.
    if Identity::at(&f.admin)?.is_some()
        || Identity::at(&f.source)?.is_some()
        || Identity::at(&f.target)?.is_some()
    {
        return Err(failure("deletion_identity_changed"));
    }
    delete_step(s, text(job, "id")?, Phase::DeleteForgetAgents, async {
        s.providers
            .agents
            .forget_workspace(text(&job["public"], "workspaceId")?)
            .await;
        Ok(())
    })
    .await?;
    let job_id = text(job, "id")?.to_owned();
    delete_step(s,&job_id,Phase::DeleteStore,update(s,job,json!({"public":{"status":"succeeded","phase":"completed","blocksWorkspace":false,"retryable":false,"verifiedAbsent":true,"error":null}}))).await
}

// Anchor every directory with an fd. Never follow an entry symlink or traverse
// a replacement root/mount. Cancellation is checked between filesystem calls.
fn remove_fenced(f: &Fence, stopped: impl Fn() -> bool) -> Result<(), ApiError> {
    f.parent_id.matches(&f.parent)?;
    let parent = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(&f.parent)
        .map_err(|_| failure("deletion_identity_changed"))?;
    if Identity::of(&parent.metadata().map_err(|_| ApiError::storage())?) != f.parent_id {
        return Err(failure("deletion_identity_changed"));
    }
    let name = std::ffi::CString::new(
        f.target
            .file_name()
            .ok_or_else(ApiError::storage)?
            .as_encoded_bytes(),
    )
    .map_err(|_| ApiError::storage())?;
    let fd = unsafe {
        libc::openat(
            parent.as_raw_fd(),
            name.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        return Err(failure("deletion_identity_changed"));
    }
    let root = unsafe { std::fs::File::from_raw_fd(fd) };
    if Identity::of(&root.metadata().map_err(|_| ApiError::storage())?) != f.root {
        return Err(failure("deletion_identity_changed"));
    }
    clear_fd(root.as_raw_fd(), f.root.dev, &stopped)?;
    if stopped() {
        return Err(failure("deletion_cancelled"));
    }
    // Do not unlink a newly substituted directory at the old name.
    f.root.matches(&f.target)?;
    if unsafe { libc::unlinkat(parent.as_raw_fd(), name.as_ptr(), libc::AT_REMOVEDIR) } != 0 {
        return Err(failure("deletion_filesystem_failed"));
    }
    parent
        .sync_all()
        .map_err(|_| failure("deletion_filesystem_failed"))
}
fn clear_fd(fd: RawFd, dev: u64, stopped: &impl Fn() -> bool) -> Result<(), ApiError> {
    if stopped() {
        return Err(failure("deletion_cancelled"));
    }
    let duplicate = unsafe { libc::dup(fd) };
    if duplicate < 0 {
        return Err(failure("deletion_filesystem_failed"));
    }
    let dir = unsafe { libc::fdopendir(duplicate) };
    if dir.is_null() {
        unsafe { libc::close(duplicate) };
        return Err(failure("deletion_filesystem_failed"));
    }
    struct Dir(*mut libc::DIR);
    impl Drop for Dir {
        fn drop(&mut self) {
            unsafe { libc::closedir(self.0) };
        }
    }
    let _dir = Dir(dir);
    loop {
        if stopped() {
            return Err(failure("deletion_cancelled"));
        }
        unsafe {
            *libc::__error() = 0;
        }
        let entry = unsafe { libc::readdir(dir) };
        if entry.is_null() {
            if std::io::Error::last_os_error().raw_os_error() != Some(0) {
                return Err(failure("deletion_filesystem_failed"));
            }
            break;
        }
        let name = unsafe { std::ffi::CStr::from_ptr((*entry).d_name.as_ptr()) };
        if name.to_bytes() == b"." || name.to_bytes() == b".." {
            continue;
        }
        let mut stat: libc::stat = unsafe { std::mem::zeroed() };
        if unsafe { libc::fstatat(fd, name.as_ptr(), &mut stat, libc::AT_SYMLINK_NOFOLLOW) } != 0 {
            return Err(failure("deletion_filesystem_failed"));
        }
        if stat.st_mode & libc::S_IFMT == libc::S_IFDIR {
            if stat.st_dev as u64 != dev {
                return Err(failure("deletion_identity_changed"));
            }
            let child = unsafe {
                libc::openat(
                    fd,
                    name.as_ptr(),
                    libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                )
            };
            if child < 0 {
                return Err(failure("deletion_identity_changed"));
            }
            let child = unsafe { std::fs::File::from_raw_fd(child) };
            let meta = child.metadata().map_err(|_| ApiError::storage())?;
            if meta.ino() != stat.st_ino || meta.dev() != stat.st_dev as u64 {
                return Err(failure("deletion_identity_changed"));
            }
            clear_fd(child.as_raw_fd(), dev, stopped)?;
            let mut current: libc::stat = unsafe { std::mem::zeroed() };
            if unsafe { libc::fstatat(fd, name.as_ptr(), &mut current, libc::AT_SYMLINK_NOFOLLOW) }
                != 0
                || current.st_ino != stat.st_ino
                || current.st_dev != stat.st_dev
            {
                return Err(failure("deletion_identity_changed"));
            }
            if unsafe { libc::unlinkat(fd, name.as_ptr(), libc::AT_REMOVEDIR) } != 0 {
                return Err(failure("deletion_filesystem_failed"));
            }
        } else if unsafe { libc::unlinkat(fd, name.as_ptr(), 0) } != 0 {
            return Err(failure("deletion_filesystem_failed"));
        }
    }
    Ok(())
}

#[cfg(test)]
pub(crate) async fn seed_crash_fixture(
    s: &AppState,
    id: &str,
    window: &str,
) -> Result<(), ApiError> {
    // Build the exact durable state left at each external Git/filesystem crash
    // boundary. Recovery itself runs in the production daemon subprocess.
    let mut job = load(s, id).await?;
    verify_delete(s, &job["workspace"], &job["command"]).await?;
    let f = capture(s, &job).await?;
    update(
        s,
        &mut job,
        json!({"fence":f,"public":{"status":"running","phase":"isolate"}}),
    )
    .await?;
    if window == "before-move" {
        return Ok(());
    }
    if window == "rename-before-metadata" {
        std::fs::rename(&f.source, &f.target).map_err(|_| ApiError::storage())?;
        fs_sync(&f.parent)?;
        return Ok(());
    }
    repo_git(
        &f,
        &[
            "worktree",
            "move",
            "--",
            path_text(&f.source)?,
            path_text(&f.target)?,
        ],
    )
    .await?;
    if window == "after-move" {
        return Ok(());
    }
    update(
        s,
        &mut job,
        json!({"removalStarted":true,"public":{"status":"running","phase":"remove-files"}}),
    )
    .await?;
    if window == "removal-intent" {
        return Ok(());
    }
    std::fs::remove_file(f.target.join("file")).map_err(|_| ApiError::storage())?;
    std::fs::remove_file(f.target.join(".git")).map_err(|_| ApiError::storage())?;
    if window == "partial-files" {
        return Ok(());
    }
    std::fs::remove_dir_all(&f.target).map_err(|_| ApiError::storage())?;
    if window == "files-removed" {
        return Ok(());
    }
    repo_git(&f, &["worktree", "remove", "--", path_text(&f.target)?]).await?;
    Ok(())
}

#[cfg(test)]
pub(crate) async fn pause_fixture(s: &AppState, id: &str) -> (Arc<Notify>, Arc<Notify>) {
    let pair = (Arc::new(Notify::new()), Arc::new(Notify::new()));
    s.deletions
        .pauses
        .lock()
        .await
        .insert(id.into(), pair.clone());
    pair
}

#[cfg(test)]
async fn pause_point(s: &AppState, key: &str) -> Result<(), ApiError> {
    let pause = s.deletions.pauses.lock().await.remove(key);
    if let Some((entered, release)) = pause {
        entered.notify_one();
        let mut closing = s.closing.subscribe();
        tokio::select! {_=release.notified()=>{},_=closing.changed()=>{}}
        cancelled(s)?;
    }
    Ok(())
}

#[cfg(test)]
pub(crate) async fn flush_diagnostics_fixture(s: &AppState) {
    s.diagnostics.flush().await;
}

#[cfg(test)]
pub(crate) async fn setup_fixture(s: &AppState, id: &str, active: bool) {
    if active {
        let (cancel, _) = tokio::sync::watch::channel(false);
        let task = tokio::spawn(std::future::pending::<Result<(), ApiError>>());
        s.setups
            .lock()
            .await
            .insert(id.to_owned(), super::SetupJob { cancel, task });
    } else if let Some(job) = s.setups.lock().await.remove(id) {
        job.task.abort();
    }
}
