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
  writes in both lanes. Uncommitted output can be lost on abrupt process/OS
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

## Evidence and limits

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
