//! Share cleanup completion, rather than treating removal from a resource map
//! as proof that asynchronous shutdown has finished.
use super::Result;
use std::{
    collections::HashMap,
    future::Future,
    sync::{Arc, Mutex},
};
use tokio::sync::watch;
type Completion = watch::Receiver<Option<Result<()>>>;
#[derive(Default)]
pub(super) struct CloseTasks {
    jobs: Arc<Mutex<HashMap<String, Completion>>>,
}
impl CloseTasks {
    pub fn ids(&self) -> Vec<String> {
        self.jobs.lock().unwrap().keys().cloned().collect()
    }
    pub async fn run(
        &self,
        id: &str,
        work: impl Future<Output = Result<()>> + Send + 'static,
    ) -> Result<()> {
        let mut result = {
            let mut jobs = self.jobs.lock().unwrap();
            if let Some(result) = jobs.get(id) {
                result.clone()
            } else {
                let (tx, rx) = watch::channel(None);
                jobs.insert(id.to_owned(), rx.clone());
                let jobs = self.jobs.clone();
                let id = id.to_owned();
                // Cancellation of one caller cannot cancel shared cleanup.
                tokio::spawn(async move {
                    let result = work.await;
                    let success = result.is_ok();
                    let _ = tx.send(Some(result));
                    // Retain failures so a racing shutdown cannot silently
                    // replace a failed cleanup with an empty successful close.
                    if success {
                        jobs.lock().unwrap().remove(&id);
                    }
                });
                rx
            }
        };
        loop {
            let current = result.borrow().clone();
            if let Some(result) = current {
                return result;
            }
            result
                .changed()
                .await
                .map_err(|_| "provider cleanup task failed".to_string())?;
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    #[tokio::test]
    async fn duplicate_close_and_cancel_wait_for_shared_result_without_blocking_other_terminals() {
        let jobs = Arc::new(CloseTasks::default());
        let count = Arc::new(AtomicUsize::new(0));
        let (entered_tx, entered) = tokio::sync::oneshot::channel();
        let (release_tx, release) = tokio::sync::oneshot::channel();
        let j = jobs.clone();
        let c = count.clone();
        let first = tokio::spawn(async move {
            j.run("slow", async move {
                c.fetch_add(1, Ordering::SeqCst);
                let _ = entered_tx.send(());
                let _ = release.await;
                Err("cleanup failed after waiting".into())
            })
            .await
        });
        entered.await.unwrap();
        first.abort();
        let _ = first.await;
        let j = jobs.clone();
        let c = count.clone();
        let mut second = tokio::spawn(async move {
            j.run("slow", async move {
                c.fetch_add(1, Ordering::SeqCst);
                Ok(())
            })
            .await
        });
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(30), &mut second)
                .await
                .is_err()
        );
        tokio::time::timeout(
            std::time::Duration::from_secs(1),
            jobs.run("other", async { Ok(()) }),
        )
        .await
        .unwrap()
        .unwrap();
        release_tx.send(()).unwrap();
        assert_eq!(
            second.await.unwrap(),
            Err("cleanup failed after waiting".into())
        );
        assert_eq!(count.load(Ordering::SeqCst), 1);
        assert_eq!(
            jobs.run("slow", async { Ok(()) }).await,
            Err("cleanup failed after waiting".into())
        );
    }
}
