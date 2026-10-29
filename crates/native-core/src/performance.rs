//! Opt-in, bounded benchmark traces. Never records paths, bodies, SQL or headers.
//! No timer, polling or sampling task is installed in the runtime.
use crate::diagnostics::Diagnostics;
use serde_json::json;
use std::{cell::RefCell, sync::OnceLock, time::Instant};
static TRACE: OnceLock<Option<(Diagnostics, Instant)>> = OnceLock::new();
tokio::task_local! { pub static REQUEST: String; }
thread_local! { static JOBS: RefCell<Vec<String>> = const { RefCell::new(Vec::new()) }; }
fn sink() -> Option<&'static (Diagnostics, Instant)> {
    TRACE
        .get_or_init(|| {
            let path = std::env::var_os("NEURA_PERF_TRACE_DIR")?;
            Diagnostics::with_limit(path.into(), 32 * 1024 * 1024)
                .ok()
                .map(|d| (d, Instant::now()))
        })
        .as_ref()
}
pub fn context() -> Option<String> {
    sink()?;
    Some(
        REQUEST
            .try_with(Clone::clone)
            .unwrap_or_else(|_| uuid::Uuid::new_v4().to_string()),
    )
}
pub fn event(id: &str, phase: &'static str) {
    let Some((d, origin)) = sink() else {
        return;
    };
    let mut usage: libc::rusage = unsafe { std::mem::zeroed() };
    let ok = unsafe { libc::getrusage(libc::RUSAGE_SELF, &mut usage) } == 0;
    let mut load = [0.; 3];
    let load_ok = unsafe { libc::getloadavg(load.as_mut_ptr(), 3) } == 3;
    let millis = |t: libc::timeval| t.tv_sec as f64 * 1000. + t.tv_usec as f64 / 1000.;
    d.performance(json!({"event":phase,"requestId":id,"monotonicMs":origin.elapsed().as_secs_f64()*1000.,
        "processCpuMs":ok.then(||millis(usage.ru_utime)+millis(usage.ru_stime)),
        "processBlockInput":ok.then_some(usage.ru_inblock),"processBlockOutput":ok.then_some(usage.ru_oublock),
        "hostLoadAverage":load_ok.then_some(load)}));
}
pub struct StoreScope;
impl StoreScope {
    pub fn enter(ids: Vec<String>) -> Self {
        JOBS.with(|v| *v.borrow_mut() = ids);
        mark("store.sqlite.begin");
        Self
    }
}
impl Drop for StoreScope {
    fn drop(&mut self) {
        JOBS.with(|v| v.borrow_mut().clear());
    }
}
pub fn mark(phase: &'static str) {
    JOBS.with(|v| {
        for id in v.borrow().iter() {
            event(id, phase);
        }
    });
}
pub fn commit<T>(f: impl FnOnce() -> T) -> T {
    mark("store.commit.begin");
    let result = f();
    mark("store.commit.end");
    result
}
pub async fn flush() {
    if let Some((d, _)) = sink() {
        d.flush().await;
    }
}
