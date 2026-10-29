//! Native provider orchestration. All mutable task state is persisted before delivery.
pub mod integration;
pub use integration::ProviderService;
pub mod agents;
pub mod claude;
pub mod codex;
pub mod event_queue;
pub mod mcp;

use serde_json::Value;
use std::{future::Future, pin::Pin, sync::Arc};
pub type Result<T> = std::result::Result<T, String>;
pub type FutureResult<'a, T> = Pin<Box<dyn Future<Output = Result<T>> + Send + 'a>>;

/// The core implements this against its sole SQLite owner. Calls must preserve
/// ordering; put resolves only after durable commit and publishes invalidation.
pub trait ProviderStore: Send + Sync {
    fn call<'a>(&'a self, operation: &'a str, args: Value) -> FutureResult<'a, Value>;
}
pub trait ProviderRuntime: Send + Sync {
    fn rpc<'a>(
        &'a self,
        terminal: &'a str,
        method: &'a str,
        params: Value,
    ) -> FutureResult<'a, Value>;
    fn reply<'a>(&'a self, terminal: &'a str, id: Value, result: Value) -> FutureResult<'a, ()>;
    fn interrupt<'a>(&'a self, terminal: &'a str, waiting: bool) -> FutureResult<'a, ()>;
}
pub type Store = Arc<dyn ProviderStore>;
pub type Runtime = Arc<dyn ProviderRuntime>;
pub fn now() -> i64 {
    chrono::Utc::now().timestamp_millis()
}
pub fn stamp() -> String {
    chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
}
pub fn id() -> String {
    uuid::Uuid::new_v4().to_string()
}
pub fn tail(value: &str, limit: usize) -> String {
    value
        .chars()
        .rev()
        .take(limit)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect()
}

#[cfg(test)]
mod tests;
