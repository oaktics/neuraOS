# Native process ownership

`process_tree::provider_host(program, args).await -> Result<i32, String>` is the
`provider-host <program> <args...>` CLI entry. Keep its stdin pipe exclusively in
the parent; EOF, SIGTERM/HUP/INT or leader exit triggers cleanup. The program's
stdin is `/dev/null`; stdout/stderr are inherited. Exit status is preserved.
No Node runtime or `ps` subprocess is involved. Long-lived Codex App Servers
are spawned directly under the shared reservation API below; there is no
per-Codex provider-host or monitor process. Close, startup cancellation and Drop
retain their Child handles until an explicit wait completes, in addition to
stopping the owned descendants.

Before opening the daemon DB/store, call
`ensure_supervisor(binary: &Path, lock_path: &Path).await`. It launches the real
native executable and waits for ready after the helper acquires the profile's
exclusive lifetime flock. The helper keeps that lock through descendant cleanup;
a restarted daemon cannot become ready against the same profile before cleanup.
A helper waiting for the lock still exits on parent EOF/termination, without
polling. Lock files are regular, same-user, single-link files opened with
O_NOFOLLOW and mode 0600, and are never unlinked as a locking mechanism.
Integration tests pass `CARGO_BIN_EXE_neura-native-core` and an isolated profile
lock path explicitly; a test-harness executable is never silently substituted.
`reserve()` before initialization is an error.

For daemon-owned external commands, call `reserve().await` to receive a
`ProcessReservation` from the single shared native `process-supervisor` helper.
This waits for the reservation ACK **before spawn**. Inject
`OWNER_ENV=reservation.token()`, spawn while retaining the unreaped child handle,
then immediately `reservation.attach(pid).await`. Keep the cloneable lease until
exit; await `stop()` for confirmed cleanup, or let final Drop enqueue cleanup.
The helper is spawned directly, never recursively under provider-host. Parent
pipe EOF (including daemon SIGKILL) stops all reservations, including a child
spawned before attach. IPC control messages are small lifecycle records and
never carry provider output. The helper's native monitor is shared across all
reservations, with no fixed live-process cap.

Low-level direct `ProcessTree` users set `OWNER_ENV` (`NEURA_PROCESS_OWNER`) to a fresh UUID
before spawning, then call `ProcessTree::new_with_token(pid, token)` immediately.
Keep the cloneable handle until exit. `stop().await` is idempotent, serializes
concurrent callers, and continues in the native monitor if the await is cancelled.
The final handle's Drop enqueues stop, but cannot wait or report an error: callers
requiring confirmation must await stop. Direct handles do not survive daemon
SIGKILL; use provider-host with the exclusive stdin lease for crash ownership.

One shared kqueue thread per process watches NOTE_FORK/EXEC/EXIT. Native libproc
snapshots follow events, control commands, shutdown deadlines and a 60-second
consistency check. Idle 10/20/32-tree fixtures observed zero snapshots in 1.6s,
versus the old per-child 250ms `ps` loop's at least 60/120/192 subprocess launches.
There is no fixed concurrency cap. NOTE_TRACK/NOTE_CHILD are not used.
provider-host remains a dedicated live PGID leader while its program runs. It
can recover non-setsid fast orphans, including restricted Apple binaries, by
matching that still-live leader's unique identity. A cached PGID alone never
proves ownership, and group-wide kill is never used; each member is individually
signalled through its audit token. Direct trees use a group only while their
original dedicated leader is alive.

An inherited random ownership token recovers detached/reparented descendants
before their transient ancestry can be observed. KERN_PROCARGS2 buffers are
bounded to 1 MiB and only the ownership UUID is retained; other environment
values are never logged or stored. Atomic BSD+unique-ID metadata identifies
processes; signals use `proc_signal_with_audittoken` with pidversion so the kernel
rejects PID reuse, including the check/signal race. There is no unsafe PID-only
fallback. TERM is followed by KILL at 1.5s; unresolved processes return an error
at 3.5s. New descendants discovered during shutdown are included.

This is cooperative process ownership, not a sandbox. Deliberately removing the
token before an unobserved fork, changing credentials to an unreadable process,
or killing the provider-host itself with SIGKILL can escape it. macOS also hides
environment variables of cs_restricted executables (including Apple system
binaries) from unentitled callers: if such a child has already lost its ancestry
before discovery, its inherited environment token cannot recover ownership. macOS offers no
supported unprivileged equivalent of a Linux cgroup for arbitrary hostile trees.
Ancestry-only `new(pid)` cannot promise recovery of already-reparented children.
These limits must not be represented as an unconditional ownership guarantee.

Evidence: `tests/native/provider-process-tree.test.mjs` compiles the synthetic C
fixture and verifies EOF, SIGTERM, parent SIGKILL, setsid/double-fork and natural
leader exit; all owned PIDs disappear and writes stop despite ignored TERM.
Rust tests exercise stale audit generation, concurrent/idempotent stop, Drop,
and independent 10/20/32 idle monitoring. Shared-helper subprocess tests stop
10 reservations on pipe EOF, 20 after parent SIGKILL, 32 on concurrent timeout
requests, and an orphan created between reserve and attach. All terminate
TERM-ignoring detached descendants and verify that writes cease. These fixtures never invoke models.

Primary API definitions and behavior:
- https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/event.h
- https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/proc_info_private.h
- https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/proc_info.c

- https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_sysctl.c (environment visibility)
