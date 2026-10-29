use serde_json::{json, Value};
use std::sync::Arc;
use tokio::sync::{mpsc, watch, OwnedSemaphorePermit, Semaphore};
const BYTES: usize = 256 * 1024;
struct Entry {
    value: Value,
    _credit: OwnedSemaphorePermit,
}
#[derive(Clone)]
pub struct EventSender {
    queue: mpsc::Sender<Entry>,
    credit: Arc<Semaphore>,
    overflow: watch::Sender<u64>,
}
pub struct EventReceiver {
    queue: mpsc::Receiver<Entry>,
    overflow: watch::Receiver<u64>,
}
pub fn channel() -> (EventSender, EventReceiver) {
    let (tx, rx) = mpsc::channel(64);
    let (overflow, changes) = watch::channel(0);
    (
        EventSender {
            queue: tx,
            credit: Arc::new(Semaphore::new(BYTES)),
            overflow,
        },
        EventReceiver {
            queue: rx,
            overflow: changes,
        },
    )
}
/// Ignore token deltas, tool output and usage: only durable lifecycle, title and
/// structured requests affect supervision. Bound copied summary text explicitly.
pub fn supervision_event(mut value: Value) -> Option<Value> {
    let method = value["method"].as_str()?.to_string();
    if value.get("id").is_none()
        && !matches!(
            method.as_str(),
            "thread/started"
                | "turn/started"
                | "turn/completed"
                | "serverRequest/resolved"
                | "thread/name/updated"
                | "thread/status/changed"
                | "item/completed"
                | "neura/disconnected"
        )
    {
        return None;
    }
    if method == "item/completed" {
        if value["params"]["item"]["type"] != "agentMessage" {
            return None;
        }
        if let Some(text) = value["params"]["item"]["text"].as_str() {
            value["params"]["item"]["text"] = json!(super::tail(text, 16000));
        }
    }
    if method == "thread/started" {
        value["params"]["thread"].as_object_mut()?.remove("turns");
        value["params"]["thread"].as_object_mut()?.remove("preview");
    }
    if method == "turn/completed" || method == "turn/started" {
        value["params"]["turn"].as_object_mut()?.remove("items");
    }
    Some(value)
}
impl EventSender {
    pub fn send(&self, value: Value) {
        let size = value.to_string().len();
        if size > 64 * 1024 {
            self.invalidate();
            return;
        }
        let Ok(credit) = self.credit.clone().try_acquire_many_owned(size as u32) else {
            self.invalidate();
            return;
        };
        if self
            .queue
            .try_send(Entry {
                value,
                _credit: credit,
            })
            .is_err()
        {
            self.invalidate();
        }
    }
    pub fn invalidate(&self) {
        self.overflow.send_modify(|v| *v = v.wrapping_add(1));
    }
}
impl EventReceiver {
    pub async fn recv(&mut self) -> Option<Value> {
        tokio::select! {biased;
         changed=self.overflow.changed()=>{if changed.is_err(){return self.queue.recv().await.map(|e|e.value)}self.overflow.borrow_and_update();while self.queue.try_recv().is_ok(){}Some(json!({"method":"neura/overflow"}))},
         entry=self.queue.recv()=>entry.map(|e|e.value)
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn byte_exhaustion_has_explicit_recovery_and_releases_credit() {
        let (tx, mut rx) = channel();
        for _ in 0..100 {
            tx.send(json!({"method":"turn/completed","params":{"padding":"x".repeat(32000)}}));
        }
        assert_eq!(rx.recv().await.unwrap()["method"], "neura/overflow");
        tx.send(json!({"method":"turn/completed"}));
        assert_eq!(rx.recv().await.unwrap()["method"], "turn/completed");
        assert_eq!(tx.credit.available_permits(), BYTES);
    }
    #[test]
    fn token_deltas_and_tool_bodies_never_enter_supervision() {
        assert!(supervision_event(
            json!({"method":"item/agentMessage/delta","params":{"delta":"x".repeat(1000000)}})
        )
        .is_none());
        assert!(supervision_event(json!({"method":"item/completed","params":{"item":{"type":"commandExecution","output":"x".repeat(1000000)}}})).is_none());
        let value=supervision_event(json!({"method":"item/completed","params":{"item":{"type":"agentMessage","text":"x".repeat(1000000)}}})).unwrap();
        assert_eq!(
            value["params"]["item"]["text"].as_str().unwrap().len(),
            16000
        );
    }
}
