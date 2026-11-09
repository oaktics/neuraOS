# Worktree performance investigation — 2026-11-09

## Source and measurement boundary

Work began at `951993e7c09f3e3f7d03a6ba03c6df65209a2515`. After fetching origin,
local staging and origin/staging matched. origin/main was `f606ec7748975abe9334d384ee341ae8ecb8dbe3`, with an identical Git tree.
All implementation worktrees were verified against this base.

Read-only sampling of the running native-67 app found 958 of 1,729 main-thread
samples under `MetalTerminalRenderer.draw`, including 937 under `buildDrawData`
and 888 under `buildDrawDataPass`. This is a three-second diagnostic sample,
not a before/after benchmark of the patch. The installed binary was not replaced.
The existing daemon log recorded a successful worktree deletion taking 27,791 ms
at 2026-11-09 03:01:59 UTC. Existing logs did not distinguish shutdown, Git and
filesystem time, so that individual delay cannot be attributed to one phase.

## Codex reconciliation

Periodic history reconciliation previously replayed every assistant message in
the latest completed turn. With multiple messages, this repeatedly replaced the
persisted final summary with intermediate summaries before returning to the final
one, generating writes and invalidations even for idle conversations.

Reconciliation now applies only the last assistant message, then completion.
Live streaming events, turn ownership checks and completion notifications retain
their existing behavior. Tool output following the last assistant message does
not replace the summary.

A deterministic fixture containing 101 assistant messages and trailing tool
output produced 102 agent revisions with the previous replay loop. The same
fixture now produces two revisions on first reconciliation and zero additional
revisions across ten unchanged reconciliations. Exactly one completion notification
is retained. The regression test was also run with the old loop and failed with
`left: 102, right: 2`, demonstrating that it detects the original behavior.

## Workspace shutdown and deletion diagnostics

Independent terminal owners now stop concurrently. All stop attempts settle even
if one fails; a failure still blocks deletion. Durable terminal state is checked
after exit notifications, with the existing timeout retained. The old 25 ms
status poll is removed.

An isolated fixture with four TERM-resistant PTYs, each with a child process,
took 6.13556 seconds with the old serial implementation and 1.63460 seconds with
the patch (about 73% less elapsed time). It checks persisted exit status, actual
leader/child disappearance and continued operation of a separate workspace.
Additional HTTP checks preserve dirty and ignored files, re-check files written
during shutdown, and verify that a failing sibling close does not cancel the
other stops. These numbers measure the shutdown fixture, not deletion of a large
real filesystem tree.

Six bounded diagnostics identify verification before/after shutdown, terminal
shutdown, Git removal, store deletion and agent cleanup. Each contains only the
operation UUID and duration; payloads, paths and error text are excluded. Both
verification passes remain necessary to catch writes made during shutdown.

## Durable deletion protocol

The shutdown optimization alone does not solve an interrupted Git removal. The
previous synchronous path had a 30-second Git subprocess timeout; killing a
large removal could leave a partially removed directory that the next attempt
would reject as dirty. Extending the client timeout would not make that operation
recoverable.

Job-capable clients now submit `workspace.delete.start`. Acceptance durably records
the command and workspace gate; it is not completion. A detached worker performs
the protected verification and shutdown, isolates the approved worktree, removes
its contents, unregisters only that worktree, and finally removes the workspace
record together with the job success transition. `workspace.delete` retains its
synchronous success semantics while waiting for the same durable worker.

A job records directory and Git metadata identity before isolation. Removal uses
file-descriptor-relative traversal and does not follow symlinks. Resumption checks
those identities rather than treating partially removed tracked files as a fresh
dirty workspace. Replacement directories, ambiguous identity, or changed Git
registration fail closed. The physical file-removal phase has no overall Git
subprocess deadline; daemon shutdown is checked between filesystem operations.
An individual blocked operating-system filesystem call remains outside that
cooperative cancellation guarantee.

Deletion admission fences new terminal launches, provider requests, queued
instructions and workspace writes. Other workspaces retain their own admission.
A failed attempt before isolation can release the workspace for editing; a failed
attempt after irreversible work keeps it blocked. Explicit retry reuses the job's
options. UI confirmation is required to create a new discard-enabled attempt;
MCP cleanup never requests discard.

The workspace snapshot includes public job progress and failure state, so UI
reconnection restores it. MCP returns a pending job when its bounded wait expires
and exposes `workspace_deletion_status` for subsequent observation. Completion
requires job success, backend absence proof, and an independent registry read.
The UI retains the workspace until an authoritative snapshot removes it.

## macOS update scope

Terminal records and workspace membership have stable observable buckets, so a
single terminal's activity change does not invalidate every workspace. Output
subscriptions are indexed by terminal ID, while connection changes still notify
all subscribers. Only the selected Git workspace retains its refresh task.

Repeated identical geometry no longer invalidates SwiftTerm. Hidden terminal
Metal views defer on-demand drawing while retaining their renderer and emulator;
showing them requests a new frame. Background parsing continues so terminal
queries and replay position remain correct.

A 1,000-workspace/terminal fixture verifies one terminal reader and one workspace
reader are invalidated by one activity change, with zero membership invalidations.
A 1,000-event fixture verifies only the targeted terminal callback is invoked.
These are deterministic work-count checks, not installed-app CPU benchmarks.

## Delivery boundary

This document records source changes and local verification. It does not claim
that the running installed app has these changes, that overall CPU or memory has
fallen by a measured percentage, or that every slow deletion shares one cause.
