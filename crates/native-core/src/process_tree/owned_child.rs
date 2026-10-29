//! Keep an unreaped leader alive as an identity anchor through cancellation.
use super::ProcessReservation;
use tokio::process::Child;

pub struct OwnedChild {
    child: Option<Child>,
    lease: ProcessReservation,
}
impl OwnedChild {
    pub fn new(child: Child, lease: ProcessReservation) -> Self {
        Self {
            child: Some(child),
            lease,
        }
    }
    pub fn child_mut(&mut self) -> &mut Child {
        self.child.as_mut().expect("owned child transferred")
    }
    /// Remove the cancellation guard only after stop/reap, or when transferring
    /// ownership to another guard. This method does not perform cleanup.
    pub fn into_inner(mut self) -> Child {
        self.child.take().expect("owned child transferred")
    }
}
impl Drop for OwnedChild {
    fn drop(&mut self) {
        let Some(mut child) = self.child.take() else {
            return;
        };
        let lease = self.lease.clone();
        if let Ok(runtime) = tokio::runtime::Handle::try_current() {
            runtime.spawn(async move {
                // Cancellation may precede attach ACK. Keep the child unreaped
                // while completing identity registration before requesting stop.
                if let Some(pid) = child.id() {
                    let _ = lease.attach(pid).await;
                }
                // No try_wait: reaping here would lose the original PGID anchor.
                let _ = lease.stop().await;
                let _ = child.kill().await;
                let _ = child.wait().await;
            });
        } else {
            // Outside a live runtime asynchronous guarantees no longer apply.
            // Best effort kill; final lease Drop still requests helper cleanup.
            let _ = child.start_kill();
        }
    }
}
