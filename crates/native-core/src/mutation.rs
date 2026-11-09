//! Resource-scoped mutation guards. Network work in one workspace never takes
//! another workspace's exclusive lock; project deletion waits for shared users.
use std::{
    collections::HashMap,
    sync::{Arc, Weak},
};
use tokio::sync::{Mutex, OwnedMutexGuard, OwnedRwLockReadGuard, OwnedRwLockWriteGuard, RwLock};
#[derive(Default)]
pub struct MutationLocks {
    catalogue: Arc<Mutex<()>>,
    projects: Mutex<HashMap<String, Weak<RwLock<()>>>>,
    workspaces: Mutex<HashMap<String, Weak<Mutex<()>>>>,
}
#[allow(dead_code)]
pub struct MutationGuard {
    catalogue: Option<OwnedMutexGuard<()>>,
    project_read: Option<OwnedRwLockReadGuard<()>>,
    project_write: Option<OwnedRwLockWriteGuard<()>>,
    workspace: Option<OwnedMutexGuard<()>>,
}
impl MutationLocks {
    pub async fn enter(
        &self,
        project: Option<&str>,
        workspace: Option<&str>,
        exclusive: bool,
        catalogue: bool,
    ) -> MutationGuard {
        let catalogue = if catalogue {
            Some(self.catalogue.clone().lock_owned().await)
        } else {
            None
        };
        let mut guard = MutationGuard {
            catalogue,
            project_read: None,
            project_write: None,
            workspace: None,
        };
        if let Some(key) = project {
            let lock = {
                let mut map = self.projects.lock().await;
                map.retain(|_, v| v.strong_count() > 0);
                match map.get(key).and_then(Weak::upgrade) {
                    Some(lock) => lock,
                    None => {
                        let lock = Arc::new(RwLock::new(()));
                        map.insert(key.into(), Arc::downgrade(&lock));
                        lock
                    }
                }
            };
            if exclusive {
                guard.project_write = Some(lock.write_owned().await);
            } else {
                guard.project_read = Some(lock.read_owned().await);
            }
        }
        if let Some(key) = workspace {
            let lock = {
                let mut map = self.workspaces.lock().await;
                map.retain(|_, v| v.strong_count() > 0);
                match map.get(key).and_then(Weak::upgrade) {
                    Some(lock) => lock,
                    None => {
                        let lock = Arc::new(Mutex::new(()));
                        map.insert(key.into(), Arc::downgrade(&lock));
                        lock
                    }
                }
            };
            guard.workspace = Some(lock.lock_owned().await);
        }
        guard
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;
    #[tokio::test]
    async fn slow_remote_workspace_does_not_block_other_workspace_but_delete_waits() {
        let locks = Arc::new(MutationLocks::default());
        let slow = locks
            .enter(Some("project"), Some("slow-gh"), false, false)
            .await;
        let barrier = Arc::new(tokio::sync::Barrier::new(2));
        let other = locks.clone();
        let b = barrier.clone();
        let fast = tokio::spawn(async move {
            b.wait().await;
            other
                .enter(Some("project"), Some("fast-file"), false, false)
                .await
        });
        barrier.wait().await;
        let fast = tokio::time::timeout(Duration::from_millis(200), fast)
            .await
            .unwrap()
            .unwrap();
        drop(fast);
        let other = locks.clone();
        let remove =
            tokio::spawn(async move { other.enter(Some("project"), None, true, true).await });
        tokio::task::yield_now().await;
        assert!(!remove.is_finished());
        drop(slow);
        tokio::time::timeout(Duration::from_millis(200), remove)
            .await
            .unwrap()
            .unwrap();
    }
    #[tokio::test]
    async fn canonical_path_add_and_attach_share_catalogue() {
        let locks = Arc::new(MutationLocks::default());
        let add = locks.enter(None, None, false, true).await;
        let other = locks.clone();
        let attach =
            tokio::spawn(async move { other.enter(Some("project"), None, true, true).await });
        tokio::task::yield_now().await;
        assert!(!attach.is_finished());
        drop(add);
        tokio::time::timeout(Duration::from_millis(200), attach)
            .await
            .unwrap()
            .unwrap();
    }
}

// Shared across server and provider dispatch. A deletion publishes its durable
// gate while holding the writer; admitted mutations check that gate after taking
// a reader and retain the reader through their last side effect. Never nest readers.
fn admission_map() -> &'static std::sync::Mutex<HashMap<String, Weak<RwLock<()>>>> {
    static MAP: std::sync::OnceLock<std::sync::Mutex<HashMap<String, Weak<RwLock<()>>>>> =
        std::sync::OnceLock::new();
    MAP.get_or_init(Default::default)
}
fn admission(id: &str) -> Arc<RwLock<()>> {
    let mut map = admission_map().lock().unwrap();
    map.retain(|_, lock| lock.strong_count() > 0);
    if let Some(lock) = map.get(id).and_then(Weak::upgrade) {
        return lock;
    }
    let lock = Arc::new(RwLock::new(()));
    map.insert(id.into(), Arc::downgrade(&lock));
    lock
}
pub async fn workspace_activity(id: &str) -> OwnedRwLockReadGuard<()> {
    admission(id).read_owned().await
}
pub async fn workspace_deletion_admission(id: &str) -> OwnedRwLockWriteGuard<()> {
    admission(id).write_owned().await
}
