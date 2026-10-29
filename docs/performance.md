# Concurrent agent performance

The product daemon, PTY, SQLite writer, provider adapters and MCP run in Rust.
The UI uses SwiftUI/AppKit and CEF native views. Development Node tooling and
external `claude`, `codex`, `git` and `gh` remain separate dependencies. Performance
and energy efficiency take priority over implementation cost; language choice
alone is not a measured speedup.

There is no arbitrary fixed agent concurrency limit. Queue byte credits, report
inbox capacity and test points such as 10/20/32 are not agent-count limits.
Actual sustained concurrency depends on machine and provider resources.

This release scope covers native runtime performance work and general extension/
signing infrastructure. [1Password usability is deferred](1password-browser.md)
and is not a prerequisite for concluding this performance release. This scope
change is not evidence of a measured speedup; the controlled comparison and
release checks remain separate.

## Current data path

- HTTP commands and authenticated WebSocket invalidations replace fixed UI state,
  terminal-output and browser polling. Consumers fetch output after their cursor;
  reconnect/replay recovers missed notifications. Input has a separate path from
  output fetch. A changed signal is not itself terminal data or task completion.
- A shared mio reactor reads PTYs. The current native output batch target is
  8 ms or 256 KiB; scheduling pressure can extend elapsed time. SQLite uses WAL
  and `synchronous=FULL`, one writer and a separate output reader. Control and
  bulk queues have separate byte credits/FIFO ordering; barriers await accepted
  writes in both lanes. Ready operation-start/finish records share a FULL/WAL
  transaction in groups of at most eight, without a batching timer. Replies
  follow commit; grouping does not cross CAS/read/barrier boundaries, and bulk
  still receives service after at most eight control jobs. A failed COMMIT is
  never replayed. This batch size is not a CLI concurrency limit.
  Uncommitted output can be lost on abrupt process/OS
  failure. Durability settings do not make queued data durable before commit.
- SwiftTerm consumes output with cooperative yields, preserving UTF-8 and resize
  order. Hidden emulators also consume output so terminal protocol replies and
  live screen state can advance without selecting the tab.
- CEF keeps native embedded views. Its callback-driven adaptive external pump
  has a 33 ms idle fallback. It is not a separate browser host. See
  [extension/pump verification](browser-extensions.md).
- One shared native process supervisor per daemon replaces per-child `ps` loops
  and per-Codex host processes. PTY, setup and Codex spawn directly after a
  reservation ACK, then attach their child PID. The helper takes a profile
  lifetime flock before the daemon opens SQLite and holds it through cleanup.
  Child guards retain/reap processes across cancellation and failed attachment.
  `provider-host` remains a compatibility/fixture entry, not the normal launch
  path. See
  [ownership guarantees and OS limits](native-process-ownership.md).

Daemon diagnostics are bounded, rotated, private operation records, with dropped
record counts. They no longer sample Node event-loop delay or JS heap. See
[reliability](reliability.md). CPU, memory pressure, IO, wakeups and energy need
separate workload measurements; swap allocation alone is not evidence of active
thrashing, and idle samples cannot explain a past busy incident.

A PTY/store failure emits a state invalidation and fails health/state/output
operations closed; input is not acknowledged as healthy after failed output
commit. The UI retries failed notification delivery with backoff while keeping
its cursor. When a daemon no longer advertises `state.stream`, it cancels the
old stream generation and returns to the legacy fallback. Healthy native idle
consumers still wait for events.

## Optimized comparison (2026-10-29)

[Full results and build metadata](architecture-evidence/optimized-legacy-native-2026-10-29.json) use an Apple M1 / 8 CPU / 16 GiB Mac on macOS 26.6.2. The native optimized local binary was built from `300baa1`; the legacy daemon used Node 24.13.0 from the same checkout. Both use SQLite WAL with `synchronous=FULL`. Each terminal emits 1,024 ordered rows with a 2,048-byte payload and Unicode marker. Two runs per runtime were performed in native→legacy→legacy→native order, with heavy build/worker jobs stopped. Normal desktop background applications remained running. Values below are the min–max across the two runs, not confidence intervals.

| PTYs | Completion ms: legacy | native | State p99 ms: legacy | native | Input p99 ms: legacy | native |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 1201.37–1636.10 | 1221.14–1737.04 | 3.14–4.47 | 1.87–6.27 | 1.97–2.30 | 1.76–11.00 |
| 5 | 1734.61–2253.98 | 1194.49–1769.90 | 19.12–62.85 | 1.85–2.39 | 3.52–3.92 | 2.58–4.28 |
| 10 | 1741.99–2726.84 | 1374.67–1966.80 | 24.22–47.14 | 5.96–6.23 | 4.91–5.40 | 4.34–4.35 |
| 20 | 2687.07–3422.42 | 1909.61–2466.65 | 53.09–111.09 | 14.23–15.46 | 8.23–8.39 | 8.66–13.86 |
| 32 | 3700.29–4075.87 | 2749.86–3270.83 | 116.85–219.41 | 19.13–47.32 | 15.19–15.81 | 19.48–26.29 |

The completion and state results improve under parallel output load, but input acceptance does **not** improve at every count. At 32 PTYs, native input p99 remains higher than legacy in both final runs. Each input percentile has only N samples (one simultaneous command per PTY); at N=1 it is a single observation. These values must not be presented as production latency distributions or an across-the-board speedup.

| PTYs | Idle CPU ms/5s: legacy | native | Idle footprint MiB: legacy | native | Interrupt wakeups/5s: legacy | native |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 57.09–59.46 | 0.13–0.15 | 81.28–94.58 | 8.16–8.24 | 545.00–546.00 | 1.00–1.00 |
| 5 | 65.39–65.80 | 0.20–0.24 | 87.91–102.10 | 17.30–17.37 | 517.00–541.00 | 1.00–1.00 |
| 10 | 71.62–72.99 | 0.33–0.34 | 112.02–112.73 | 28.58–28.79 | 543.00–564.00 | 1.00–2.00 |
| 20 | 114.53–126.94 | 0.55–0.59 | 129.29–137.52 | 51.09–51.21 | 535.00–542.00 | 1.00–1.00 |
| 32 | 140.55–141.73 | 0.74–1.43 | 160.63–161.55 | 77.69–78.15 | 539.00–553.00 | 1.00–1.00 |

Every point recorded zero HTTP errors, missing or duplicate rows, intact Unicode, and identical durable replay after restart. Counters cover stable daemon descendants only; short-lived child costs are excluded. Footprint is measured after the 5-second idle window, not at peak load. Legacy idle readers follow the former UI cadence (state 1s, visible output 60ms, other output 500ms); native readers wait for events.

The CPU sampler converts Mach ticks using `mach_timebase_info`. [Independent CPU-burn validation](architecture-evidence/cpu-counter-unit-validation-2026-10-29.json) matched `getrusage`; the initial unconverted local CPU results were rejected and the full comparison rerun. [Operation group-commit evidence](architecture-evidence/store-operation-group-commit-2026-10-29.json) records the focused optimization and failure regressions.

This workload includes real PTYs and synthetic output, not real Claude/Codex model work, Swift UI rendering or CEF. It establishes neither battery-life gains nor a universal fastest architecture. Memory/CPU improvements here describe the measured daemon tree, not the whole application or all CLI processes.

Reproduce from the repository root after building the release binary and installing development dependencies:

```sh
cc -O2 -Wall -Wextra -Werror tests/native/fixtures/process-metrics.c -o /tmp/neura-process-metrics
NEURA_BENCH_COUNTS=1,5,10,20,32 NEURA_BENCH_ROWS=1024 NEURA_BENCH_IDLE_MS=5000 NEURA_BENCH_METRICS=/tmp/neura-process-metrics node scripts/native/benchmark-native-daemon.mjs
NEURA_BENCH_COUNTS=1,5,10,20,32 NEURA_BENCH_ROWS=1024 NEURA_BENCH_IDLE_MS=5000 NEURA_BENCH_METRICS=/tmp/neura-process-metrics NEURA_BENCH_COMMAND='["node","--import","tsx","apps/daemon/src/main.ts"]' node scripts/native/benchmark-native-daemon.mjs --legacy
```

Repeat in the reverse order and retain all results. These commands use disposable daemon data and do not update the installed app.

## Earlier evidence and limits

The [legacy real-PTY sample](architecture-evidence/legacy-daemon-pty-2026-10-29.json)
and [native debug sample](architecture-evidence/native-debug-pty-2026-10-29.json)
exercise 10/20/32 real PTYs with synthetic output. They recorded zero HTTP errors,
missing lines or duplicates and matching cursor replay. The native sample used
a debug build while other builds/agents ran. It does **not** establish optimized
release performance, real Claude throughput, battery life or a fair speedup.

The [native provider launch fixture](architecture-evidence/native-provider-daemon-parallel-2026-10-29.json)
uses the real native daemon and ProviderService with fake Claude/Codex CLIs at
10/20/32 each. All six cases reached the requested simultaneous active count;
seven tests including the parent passed, with zero remaining fixture processes.
Its elapsed times are functional-test timings, not model throughput or a fair
legacy/native performance comparison. Reconnection here means the UI event
stream plus output cursor replay, not provider App Server reconnect.

The [Node/Rust/Node migration fixture](architecture-evidence/legacy-native-data-migration-2026-10-29.json)
checks real daemons against one isolated database, including Unicode output,
settings, notifications, operation results and task inboxes. It does not apply
an update to the installed app or switch the real user's LaunchAgent.

[The architecture investigation](architecture-concurrency-energy-2026-10-29.md)
separates the current integration from proposed UDS/shared-memory transport,
segmented journals and a separate browser host. Those proposals are not shipped
features. Its dated legacy measurements remain historical evidence.

The retained `node scripts/native/benchmark-output.mjs` benchmark uses the legacy
Node SQLite path with temporary databases, ten terminal IDs and 2,000 chunks,
five runs per mode. Earlier observed medians of 274 ms unbatched and 16 ms batched
were storage-burst timings for that implementation. They are not native-runtime
results or proof that ten live Claude sessions fit within 16 GB. Do not overwrite
historical evidence when rerunning a harness.

Before claiming a performance improvement, compare optimized builds with the
same workload, durability and functionality, repeat under controlled load, and
report throughput, p99, backlog, CPU/IO/memory and energy separately. Protocol
fixtures, signed/notarized distribution, rollback and installed-app acceptance
are distinct verification steps.
