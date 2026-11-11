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
  8 ms or 256 KiB; scheduling pressure can extend elapsed time. A batch whose
  predecessor committed at least 8 ms earlier also closes after 2 ms without new
  bytes, so isolated output is not held for the whole window. Queued reads of one
  PTY are gathered per reactor turn, and a terminal's chunks inside one batch are
  merged into rows of about 32 KiB (decoding a carried partial sequence or
  invalid bytes can make a row larger). SQLite uses WAL and `synchronous=FULL`,
  one writer, a read-only connection for output pages and a second read-only
  connection for state, entity, notification and event reads. Each read request
  uses one WAL snapshot. Entity reads (`get`, `list`, `state`) first wait for every
  control-lane write already accepted, so they keep the ordering of the writer
  FIFO even when a write's caller has gone away; client polling of `/v1/state`,
  output, notifications and events does not wait. Every reader-served request
  fails closed once the writer thread is gone. Operation lookups and deletion
  gates stay on the writer FIFO. See [the 2026-11-11 measurements](#read-lanes-row-gathering-and-interactive-echo-2026-11-11). Control and
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

Resize requests share the bounded output FIFO with already-read bytes and pending spill data. The target PTY pauses reads until its resize marker is durably committed; only then does the daemon apply the ioctl and resume reads. Input and other PTYs remain active. An accepted resize completes even if its HTTP caller disconnects. Storage failure fails the runtime closed, and replay retains the same data/resize order, including partial UTF-8 across a resize.

## Optimized comparison (2026-10-29)

[Full results and build metadata](architecture-evidence/optimized-legacy-native-2026-10-29.json) use an Apple M1 / 8 CPU / 16 GiB Mac on macOS 26.6.2. This is the `a61effc` performance checkpoint, before the subsequent process-exit registration fix, not a measurement of the published release artifact. The native optimized local binary was built from `a61effc`; the legacy daemon used Node 24.13.0 from the same checkout. Both use SQLite WAL with `synchronous=FULL`. Each terminal emits 1,024 ordered rows with a 2,048-byte payload and Unicode marker. Two runs per runtime were performed in native→legacy→legacy→native order, with heavy build/worker jobs stopped. Normal desktop background applications remained running. Values below are the min–max across the two runs, not confidence intervals.

| PTYs | Completion ms: legacy | native | State p99 ms: legacy | native | Input p99 ms: legacy | native |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 1250.88–1847.56 | 1136.00–1196.56 | 1.51–192.25 | 2.36–3.96 | 2.36–10.20 | 2.44–2.56 |
| 5 | 1677.42–1713.02 | 1251.30–13936.48 | 14.93–23.88 | 4.09–3323.22 | 3.99–10.44 | 3.87–48.56 |
| 10 | 1855.96–1988.00 | 1374.66–1934.19 | 54.09–120.22 | 6.92–21.18 | 6.46–8.56 | 3.74–17.40 |
| 20 | 2920.88–3011.46 | 1899.07–2202.94 | 85.80–110.67 | 21.25–28.60 | 8.08–8.44 | 11.22–12.20 |
| 32 | 3723.99–3933.47 | 2784.93–2859.19 | 86.66–194.02 | 23.64–127.88 | 11.36–13.53 | 9.76–91.67 |

Results are variable and do **not** establish an across-the-board latency improvement. Native completion at 10/20/32 PTYs was faster in these runs, while the first native 5-PTY run took 13.94s and had a 3.32s state p99; the reversed-order native run took 1.25s with 4.09ms state p99. The outlier is retained. Background applications remained active, but no trace established its cause, so it is not attributed to host contention. Input acceptance also regresses at some counts/runs. Each input percentile has only N samples (one simultaneous command per PTY); at N=1 it is a single observation. These values are not production latency distributions.

| PTYs | Idle CPU ms/5s: legacy | native | Idle footprint MiB: legacy | native | Interrupt wakeups/5s: legacy | native |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 59.46–61.23 | 0.16–0.18 | 91.00–92.98 | 8.36–8.49 | 505.00–541.00 | 1.00–1.00 |
| 5 | 61.00–73.24 | 0.26–0.72 | 99.85–100.14 | 17.51–17.66 | 511.00–548.00 | 1.00–2.00 |
| 10 | 71.74–100.41 | 0.31–0.37 | 101.59–101.62 | 28.43–28.84 | 524.00–593.00 | 1.00–2.00 |
| 20 | 94.99–98.58 | 0.51–1.30 | 130.29–130.96 | 50.80–51.10 | 556.00–599.00 | 1.00–2.00 |
| 32 | 148.20–175.44 | 0.77–1.20 | 160.49–160.91 | 77.71–78.19 | 612.00–633.00 | 1.00–2.00 |

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

## Tail-latency evidence (#141)

[Functional acceptance evidence](architecture-evidence/tail-latency-idle-barrier-2026-10-30.json)
records the ABBA fixture results and MCP barrier matrix, including the failed
first attempt. These are not optimized speed or battery measurements.

`NEURA_PERF_TRACE_DIR` explicitly enables a private, bounded diagnostic trace for
an isolated benchmark daemon. It is off by default. Enabling it installs no
runtime polling timer and no agent-count limit. The benchmark writes UUID
`x-neura-perf-id` correlation headers; the server accepts only UUIDs and never
exports request paths, tokens, SQL, arguments, terminal data or conversation text.
Invalid correlation headers are replaced with a generated UUID.

The runtime trace records `http.received`, `store.queue.begin`,
`store.sqlite.begin/end`, `store.commit.begin/end` and `http.response`. Queue time
includes admission/byte-credit waiting and FIFO waiting. Explicit transaction
commit is measured around COMMIT itself; `store.autocommit.begin/end` includes the
whole standalone operation statement and its implicit commit, so it must not be
interpreted as fsync-only time. Group commits attach the same transaction interval
to every participating request. Background work without an HTTP context receives
its own UUID. Detached `agent.instruction` mutations explicitly inherit the HTTP
request context so their store intervals remain correlated even after client
disconnect; unrelated background tasks remain separate work.
HTTP response time is handler response construction, not socket delivery or client
body decoding. Cancellation can leave an incomplete HTTP interval; committed store
work is still recorded even when its reply receiver has gone away.

Rows carry a process-session ID, a monotonic millisecond offset, UTC timestamp,
process CPU and block-I/O counters and host load average. Use monotonic offsets for
intervals within one daemon lifetime and UTC for joining benchmark samples across
processes; wall-clock adjustments can affect cross-process joins. The benchmark's
active-workload-only `pressure.jsonl` adds CPU tick counters, load average and,
when `NEURA_BENCH_METRICS` is supplied, stable-process CPU/runnable-time and disk
read/write byte counters. It includes the sampling duration. These are pressure
indicators, not proof of contention or a direct filesystem fsync latency counter;
zero/unsupported block-I/O counters are not evidence of no disk activity. Sampling
and trace logging themselves add overhead. Do not mix traced measurements with an
untraced speedup comparison.

The writer uses a bounded 256-row channel, two rotated files of approximately
32 MiB each, and private 0700/0600 permissions. Saturation/file failures produce
`droppedEvents` on a later successful record. Rotation can also remove early
intervals. Missing records or unmatched starts mean evidence is incomplete; they
must not be assigned zero duration or used to exonerate a subsystem. There is no
unbounded in-memory trace buffer or synchronous trace-file write on the HTTP/store
executor.

Reproduce the sequential native→legacy→legacy→native order at 1/5/10/20/32 PTYs:

```sh
cc -O2 -Wall -Wextra -Werror tests/native/fixtures/process-metrics.c -o /tmp/neura-process-metrics
NEURA_BENCH_METRICS=/tmp/neura-process-metrics \
NEURA_BENCH_EVIDENCE=/tmp/neura-tail-evidence \
NEURA_BENCH_ROWS=1024 NEURA_BENCH_IDLE_MS=5000 \
node scripts/native/benchmark-order.mjs
node scripts/native/analyze-latency.mjs /tmp/neura-tail-evidence/1-native/5
```

Build the optimized native binary first. Optional `NEURA_BENCH_NATIVE_COMMAND`
and `NEURA_BENCH_LEGACY_COMMAND` are JSON argv arrays, not shell commands.
`NEURA_BENCH_COUNTS` overrides only the benchmark points, never runtime concurrency.
Each count uses disposable data and synthetic PTYs, checks exact output order,
Unicode, no missing/duplicate rows, and identical replay after fixture restart.
The installed app and its daemon are never restarted. Successful external evidence
is retained while temporary workload data is removed; failed fixtures are retained.

`http-outliers.jsonl` retains request UUIDs for requests above
`NEURA_BENCH_SLOW_MS` (default 100 ms), HTTP failures and transport/timeouts. Set
this threshold to 0 when validating the join. The analyzer joins those UUIDs to
runtime intervals and nearby pressure samples, including unfinished intervals,
`httpComplete` describes only the presence of HTTP start/end, not proof that every
store event survived. It does not choose a root cause. The Rust injection test holds an explicit commit
behind a test-only condition-variable gate, observes a second request's queue
entry, then releases the commit. It proves slow commit and queue waiting are
separate intervals without exposing a runtime injection endpoint. The existing
WAL/FULL group commit, failed-commit and durable replay tests remain applicable.
No claim is made about the original unreproduced outlier or battery-life effects.

## Native MCP idle barrier (#145)

`tests/native/provider-native-mcp.test.mjs` exercises 10/20/32 clients with ready
delivery delayed by 0 and 800 ms. The fixture first observes one completed initial
channel HTTP response for every terminal, sends ready only after that barrier,
then observes each terminal's ready-triggered completed response before beginning
the idle window. A WebSocket upgrade count alone is not a readiness barrier.
Reconnect uses the same per-terminal response-completion barrier. Each initial
and reconnect window requires exactly zero HTTP growth over 1.6 seconds; targeted
changes require exactly one HTTP request, unrelated state changes require zero,
and consumed instructions must not be delivered again. Delay variation is a
fixture perturbation, not an increased grace sleep or relaxed HTTP allowance.

## Read lanes, row gathering and interactive echo (2026-11-11)

[Raw runs](architecture-evidence/daemon-read-lanes-row-gather-2026-11-11.json)
compare `eb8d0ce` (staging) with `d219a2c` on the same Apple M1 / 8 CPU / 16 GiB
Mac. Two other agents were compiling Swift and Rust during every run (1-minute
load average 3.7 to 9.4 when each run ended), so elapsed and CPU times are noisy and are reported only
as ranges. Each workload ran eight times in baseline, candidate, candidate,
baseline order, twice, untraced (`NEURA_BENCH_TRACE=0`). Values are min–max over
the four runs per binary, not confidence intervals. The 2026-10-29 tables above
are unchanged historical evidence from a different checkout and a quieter host;
do not join them with these rows.

What changed in the daemon:

- `get`, `list`, `state`, notification and event reads use a read-only connection
  on its own thread instead of the writer queue. Replies still follow commit.
  Entity reads used by handlers (`get`, `list`, `state`) wait until the writer has
  finished every control-lane write accepted before the read, exactly the order
  they had on the writer FIFO; with nothing queued that is one comparison. This
  was added after review: without it a write whose caller disconnected before the
  reply could be invisible to the next handler's read-modify-write. The client
  polling paths (`/v1/state`, output pages, notifications, events) do not wait.
  All reader-served requests return a storage error once the writer has exited.
- `/v1/terminals/{id}/output` is one read-only request that returns the terminal
  status and the page from the same snapshot, encoded directly from SQLite text.
  `/v1/state` is assembled from the stored rows as validated text. Members, member
  order and paging limits are the same as before.
- PTY output reaches the writer as typed rows. It was previously copied into a
  JSON tree, cloned, and serialized once more only to count queue credits.
- A macOS PTY returns at most 1 KiB per read. The reactor now gathers what is
  queued (up to 32 KiB) in one turn and the batch merges a terminal's chunks up
  to 32 KiB, instead of one stored, indexed and re-encoded row per KiB. A row is
  not capped exactly: a full read plus a carried partial UTF-8 sequence decodes
  to a few bytes more, and invalid bytes expand to U+FFFD.
- The event stream announces terminal output at once when it has sent nothing
  for 48 ms. State, agent and browser changes, and output on a busy stream, keep
  the 16 ms gather, so the notification rate under load is unchanged.
- `terminal.input` and `terminal.resize` keep the project guard and the deletion
  admission but no longer take the per-workspace mutation mutex.
- The WAL file is truncated to 64 MiB after a checkpoint resets it
  (`journal_size_limit`). FULL/WAL durability and checkpointing are unchanged.

Bulk workload (1,024 rows of 2,048 bytes per PTY, the published workload, with a
state request every 50 ms):

| PTYs | Daemon instructions, millions: before | after | Daemon disk writes MB: before | after | Completion ms: before | after | Input p99 ms: before | after | State p99 ms: before | after |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 422–467 | 275–298 | 8.4–8.7 | 4.5–4.7 | 1559–2844 | 1925–2790 | 1.8–12.3 | 2.6–5.8 | 3.5–27.8 | 4.3–35.7 |
| 5 | 1767–1826 | 1001–1111 | 39.2–40.0 | 26.3–27.4 | 1919–2018 | 1910–2235 | 3.8–15.9 | 3.5–5.8 | 2.6–12.9 | 2.0–6.8 |
| 10 | 3385–3412 | 1807–1882 | 80.2–81.0 | 51.8–52.7 | 2072–2192 | 2026–2187 | 10.5–29.1 | 4.2–7.9 | 7.3–16.1 | 3.9–24.6 |
| 20 | 6475–6574 | 3414–3449 | 175.2–178.8 | 108.1–109.0 | 2473–2917 | 2137–2406 | 28.5–45.8 | 12.4–33.0 | 9.0–34.5 | 7.0–29.1 |
| 32 | 10497–10772 | 5295–5468 | 320.9–325.1 | 184.7–185.4 | 3187–4064 | 2263–3138 | 81.3–109.8 | 11.4–24.1 | 17.6–108.4 | 16.7–40.5 |

Retired instructions and disk bytes of the daemon process do not overlap between
the binaries at any count (35% to 49% fewer instructions, 32% to 46% fewer bytes
written). They are counters from `proc_pid_rusage` and depend little on host
load; the same run's CPU time varied by up to a factor of two with the core type
and contention, which is why it is not tabulated. Completion time separates only
at 20 and 32 PTYs, input p99 only at 10 and 32 PTYs. **State p99 overlaps at
every count: no state-latency improvement is established by this workload**, even
though state reads no longer queue behind commits. Each input percentile still
has only N samples. The idle tree footprint after one second was 8.5–8.8 MiB
before and 8.8–9.1 MiB after at one PTY (one more connection and thread) and
within 0.3 MiB at the other counts.

Paced workload (one PTY, 300 chunks of about 100 bytes, one roughly every 140 ms
on this host, a state request every 50 ms, then 40 single-character echo trials
on the idle shell):

| | Daemon instructions, millions | Change messages | Echo p50 ms | Echo p90 ms |
| --- | ---: | ---: | ---: | ---: |
| before | 687–692 | 341–345 | 32.3–36.2 | 38.2–40.3 |
| after | 469–484 | 345 | 5.8–9.7 | 8.7–20.9 |

Echo is the time from sending one `terminal.input` until the event-driven reader
has fetched the resulting output. It includes the harness and loopback HTTP, and
excludes SwiftTerm rendering. The earlier value is mostly the fixed 8 ms batch
window plus the 16 ms stream gather; the new path waits 2 ms for the PTY to
settle and announces at once on a quiet stream. The number of change messages
did not increase.

Deterministic checks, independent of timing:

- The 32-PTY fixture stores 8,490,304 bytes as 332 to 371 rows (three runs). One
  row per read could not use fewer than 8,292. How far rows merge depends on
  scheduling, so the test asserts only a mean row above 1,024 bytes, which one
  row per read cannot reach.
- `client_reads_do_not_wait_for_a_busy_writer_and_entity_reads_stay_ordered`
  parks the writer behind a per-test hold with a second write queued. The encoded state, event, notification and output reads must complete;
  an entity read must stay pending until the queued write commits and then see
  it. It also checks 50 write-then-read rounds and a compare-and-swap update.
- `entity_reads_observe_accepted_writes_whose_caller_went_away` parks the
  writer, enqueues a put behind it, drops that future, then reads (alternately
  before and after releasing the writer), modifies and writes, 200 times: zero stale reads
  and zero lost updates. With the ordering wait removed it fails.
- `reader_served_requests_fail_closed_once_the_writer_is_gone` stops the writer
  and requires state, entity, list, event, notification and output reads to
  return an error. With the liveness check removed they keep succeeding.
- `encoded_state_and_output_pages_equal_the_value_forms` compares the directly
  encoded state and output bodies with the previous value-tree forms, including a
  deletion overlay, escapes, a resize marker, paging limits, a missing terminal
  and a corrupt stored row (which must fail closed).
- The protocol suite types into one shell while another shell of the same
  workspace, which ignores TERM, is being stopped. On `eb8d0ce` that input waited
  1,557 ms for the stop; it must now complete while the stop is still pending.

Profiled and left unchanged:

- The published idle footprint growth of about 2.2 MiB per PTY is the fixture's
  login shell (2.15 MiB each at 20 PTYs). The daemon and supervisor together
  measured 8.5 MiB with 20 idle PTYs.
- Each output commit writes about 13.5 KiB of WAL for a small chunk (table leaf,
  `output_terminal` index leaf and the `AUTOINCREMENT` sequence page). Removing
  the index or `AUTOINCREMENT` would change the schema shared with older
  daemons and was not attempted. In a 1 ms sample of the paced workload SQLite
  commit I/O (`pwrite`, `fsync`) was the largest single item, about a fifth of
  daemon CPU; the rest was spread over HTTP, the stream and the runtime.
- The process supervisor takes a full process-table snapshot (one `proc_pidinfo`
  per process, about 1,600 on this host) for every fork, exec and exit event in
  an owned tree. On the installed daemon it had used 30 s of CPU in 23 minutes
  of agent builds, more than the daemon itself (11 s). Coalescing those
  snapshots would widen the window in which a short-lived parent can disappear
  unobserved, so it was not changed without an ownership review.

Rerun after the review fix (`449daa5`, `reviewFixRerun` in the raw file). The
tables above are from `d219a2c`, before entity reads were made to wait for
accepted control-lane writes. `terminal.input` performs such reads, so the 10-
and 32-PTY bulk points were rerun in the same order twice and the paced workload
once (two runs per binary):

| | Daemon instructions, millions: before | after | Input p99 ms: before | after | State p99 ms: before | after | Completion ms: before | after |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 10 PTYs | 3386–3475 | 1797–1856 | 15.2–21.8 | 8.3–11.7 | 5.6–12.4 | 5.4–19.4 | 1980–2434 | 1904–2032 |
| 32 PTYs | 10492–10700 | 5335–5450 | 61.4–134.7 | 17.1–29.6 | 44.9–248.1 | 15.6–35.6 | 3329–3986 | 2376–2829 |

Instructions and disk bytes (51.7–51.9 and 183.6–185.9 MB) are the same as in
the `d219a2c` rows. Input p99 still does not overlap the baseline at these two
counts, but the candidate's ranges sit somewhat higher than the `d219a2c` ones
(4.2–7.9 and 11.4–24.1 ms); with four noisy runs each that difference is not
established either way, and it is the expected direction, since input reads
again wait for queued control writes. The 32-PTY state p99 ranges do not overlap
in this series; they did overlap in the first one, so the statement that no
state-latency improvement is established stands. Paced workload: 744–747 before
and 522–524 million instructions after, 345 change messages in every run, echo
p50 35.5–36.1 ms before and 9.5–10.1 ms after, p90 38.5–40.7 and 13.6–15.2 ms.

The branch's later commit resolves a Claude transcript path once per file-event
wake instead of once per changed path (terminals x events `realpath` calls when
sessions share a project directory). It has the same predicate, is not on the
measured path, and was not benchmarked separately; it is included in the rerun
above.

Not established: any effect on real Claude/Codex sessions, on the installed app,
on battery life (the per-process billed-energy counter read zero in every
sample), or on the unreproduced 2026-10-29 outlier.

The harness additions are opt-in and leave the default workload unchanged:
`NEURA_BENCH_TRACE=0` (no `NEURA_PERF_TRACE_DIR`), `NEURA_BENCH_PAYLOAD`,
`NEURA_BENCH_ROW_SLEEP_MS`, `NEURA_BENCH_ECHO` (number of echo trials) and
`NEURA_BENCH_STATE_POLL_MS`. With `NEURA_BENCH_METRICS` each result also carries
`workloadMetrics` for the active window. To reproduce one pair:

```sh
cc -O2 -Wall -Wextra -Werror tests/native/fixtures/process-metrics.c -o /tmp/neura-process-metrics
NEURA_BENCH_TRACE=0 NEURA_BENCH_METRICS=/tmp/neura-process-metrics NEURA_BENCH_IDLE_MS=1000 \
NEURA_BENCH_COUNTS=1,5,10,20,32 NEURA_BENCH_ROWS=1024 node scripts/native/benchmark-native-daemon.mjs
NEURA_BENCH_TRACE=0 NEURA_BENCH_METRICS=/tmp/neura-process-metrics NEURA_BENCH_IDLE_MS=1000 \
NEURA_BENCH_COUNTS=1 NEURA_BENCH_ROWS=300 NEURA_BENCH_PAYLOAD=64 NEURA_BENCH_ROW_SLEEP_MS=30 \
NEURA_BENCH_ECHO=40 node scripts/native/benchmark-native-daemon.mjs
```

Set `NEURA_BENCH_COMMAND` to a JSON argv array to select the other binary, and
`NEURA_BENCH_EVIDENCE` to keep only the small evidence directory; without it the
whole disposable fixture, including its database, is retained under the system
temporary directory.
