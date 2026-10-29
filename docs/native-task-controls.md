# Native task queries and instruction lifecycle

The Rust daemon and its native MCP bridge provide these controls. No installed
app restart, live queue migration or data editing is needed to run the isolated
regressions below.

## Validation and retries

Every mutating MCP tool documents `operationId` as a UUID in both the tool
and property descriptions (not only JSON Schema `format`). Reuse the same UUID
with the identical request to recover its original result. A different payload
with the same UUID is an operation conflict. A journal entry left pending across
an uncertain crash returns `operation_unknown`, never an invented success.

Validation returns `invalid_request`, `field` and `reason`: `required` for an
absent field, `expected_uuid` for a malformed UUID, and `invalid_value` for other
field failures. It does not return submitted values, instruction text or tokens.
The native bridge diagnoses missing/malformed operation IDs before HTTP; the
HTTP contract independently validates the envelope and command fields.

## List protocol

`task_list({})` preserves the full legacy response and its global daemon
revision (also used by `task_wait`). Any nonempty options object uses the query
protocol and its separate **list revision and epoch**:

```json
{"taskIds":["123e4567-e89b-42d3-a456-426614174000"],"summaryOnly":true,"limit":50}
```

Optional `taskIds`, `workspaceId` and scalar `status` combine by intersection.
`summaryOnly` omits summary text, pending/report/instruction bodies, requests and
watch bodies. It returns identifiers, status, current/last turn, per-task
revision, counts, and unread/unnotified report indicators. Unread means reports
not explicitly acknowledged; notification alone is not acknowledgment. No list
mode consumes an instruction or acknowledges a report.

Query results are sorted by task ID. Page size defaults to 500 (maximum 500),
which limits only a response, never the number of agents. Pass `nextCursor` as
`cursor` with the same options until it is null. Pages are fenced to one list
revision and epoch. A concurrent change invalidates the cursor and returns
`fullRefreshRequired: true`; discard incomplete pages and start again.

For deltas, reuse the query response's `revision` as `sinceRevision` and `epoch`
as `sinceEpoch`, and `filter` as `sinceFilter`, keeping the same filters.
A changed or missing filter fingerprint returns `fullRefreshRequired: true`
with `reason: filter_changed`; changing a filter needs a fresh baseline, since
unchanged tasks matching the new filter would otherwise be missing from a delta.
Apply returned `agents` by ID and
remove `removedTaskIds`. For the `currentSessionIds` cache, first remove all
`removedSessionTerminalIds`, then apply returned map entries. Binding-only
close/SessionEnd/resume changes advance list revision even if the persisted
Agent row is unchanged. Tombstones retain prior terminal IDs, so moving the same
session from one terminal to another or deleting its workspace removes old
map entries. Apply all pages before advancing the cache revision.
Removal IDs include changed tasks no longer matching
the filter, even if the client did not previously cache that ID. They also
include actual registry deletion. Deleting an absent cache ID is harmless.
An empty full result (`delta: false`) differs from no new changes
(`delta: true, unchanged: true`). Unrelated changes can produce an empty delta
with `unchanged: false`; still advance the revision after all pages are applied.
The change journal retains the last 4096 changes. Old/future revisions, missing
or mismatched epochs and restart boundaries require an explicit full refresh.
Only then restart without `sinceRevision`, `sinceEpoch`, `sinceFilter` and `cursor`.

Filtering/projection happen under the daemon's registry lock before serialization;
summary mode never clones or serializes the long body fields. Query responses
retain the legacy meaning of `currentSessionIds` (current Claude sessions),
limited to returned rows. Use task IDs and terminal IDs for Codex discovery.

## Exact instruction operations

`task_send(mode: queue)` returns a stable `messageId`. The pending entry has
`state: queued` and a transition history. `task_read` exposes pending entries,
archived `instructions`, and the task's durable `revision`. Reads do not consume.
Use `task_instruction` with all of:

- `operationId`: UUID, reused for identical retries.
- `taskId` and `instructionId`: exact IDs, never inferred from text.
- `expectedRevision`: the task revision from the reviewed snapshot.
- `expectedTurnId`: current turn UUID, or **explicit null** when no turn exists.
- `expectedState`: `queued` or `delivered` from that instruction.
- `action`: `consume`, `cancel` or `supersede`; replacement `text` for supersede.

Consume is self-only and records processed work, including queued work already
handled during a long turn. Cancel/supersede allow the target itself or its
registered parent, and only for queued instructions. Supersede preserves queue
position and unrelated instructions; removal, replacement and history are one
SQLite row update. History records state, timestamp, actor task, and replacement
ID. Completed records (`consumed`, `cancelled`, `superseded`) retain at most
128 records and 256 KiB of serialized JSON, newest completion timestamps first.
Old completed records are evicted; `instructionHistoryPruned` is the persistent
cumulative count. Pending and all unconsumed/in-flight/unknown records are never
evicted, even when they exceed that budget. The active-work set can therefore
still grow and must be explicitly resolved by its owner; completed transcript
retention cannot silently discard uncertain work. Original operation UUID
retries still replay their journal results after history eviction; results also
retain the actor task ID. A new operation targeting an evicted instruction fails
as missing. This is bounded operational history, not an indefinite transcript
archive. A task/turn/revision/state conflict fails without changing the queue.
`task_ack` remains exclusively for exact report IDs.

MCP injects its launch-bound terminal identity; an argument cannot override it.
The daemon resolves the currently selected Codex session or current Claude
session for that terminal before checking self/parent authority. Discovered old
Codex conversations cannot grant parent authority. The local HTTP bearer-token
API is a trusted administrative boundary, as for existing source-terminal
commands; possessing that credential is not an untrusted-agent sandbox.

Codex delivery persists `delivering` before RPC, then `delivered` on a valid
turn result or `unknown` on transport/protocol failure. Restart converts any
persisted `delivering` to `unknown`, never back to queued. Claude persists
`delivered` **before the HTTP reply** handing the Channels payload to the transport; this means
**dispatch, not proof of actual CLI receipt or completion**. Lost Channels responses are
not retried automatically. Both providers retain instruction ID and history.
Delivered/unknown/in-flight instructions cannot be reported as successfully
cancelled or superseded. Explicit self-consume is the owner's processing
acknowledgment, not daemon proof of external side effects.
No lifecycle operation rolls back or stops already executing CLI work. Unknown
Codex delivery rejects consume as well as cancel/supersede; inspect the
conversation and provider state instead of treating uncertainty as success.

Lifecycle HTTP operations complete their registry write and operation journal
even when the caller disconnects. A process crash between those commits retains
the existing `operation_unknown` fence. Inspect the durable snapshot rather
than blindly submitting a new operation ID. Legacy `task_interrupt` still
cancels all queued instructions and watches, now retaining cancellation history.

## Regression evidence

- `contracts::tests`: missing/malformed UUIDs, different invalid fields, no value
  reflection, required exact lifecycle fences.
- `providers::tests::instruction_tests`: active-turn consume, parent cancellation,
  atomic supersede, unrelated instruction preservation, delivery after turn end,
  sibling denial, cancel/supersede race, delivery transport failure, restart,
  read-only read/list, deletion/hidden-task deltas, paging and cursor expiration,
  count/byte retention with unconsumed/unknown bodies preserved across restart,
  binding-only close/SessionEnd, terminal resume, rebind/filter and map deletion.
- 40 stopped tasks with long pending/report bodies: measured JSON response sizes
  **1,906,435 bytes full / 19,875 bytes summary** in the isolated Rust fixture.
  These are UTF-8 byte lengths for this fixture, not a general reduction target.
- `tests/native-rust/migration.test.mjs`: real Node → Rust → Node startup
  roundtrip, seeding both old records without lifecycle fields and new records.
  Verifies queued defaults, complete pending history, consumed/cancelled/
  superseded/delivered/unknown history, delivering-to-unknown recovery, revision
  and pruning counters. Native API/SQLite and rollback Node API/SQLite remain
  equal even after a legacy `agent.ack` write. Existing journal/output/settings
  assertions remain. This tests rollback data preservation, not availability of
  the new lifecycle API in the legacy runtime.
- `tests/native/task-control.test.mjs`: real native daemon + native MCP stdio +
  synthetic external CLI; tools/list descriptions, HTTP and MCP diagnostics,
  same-operation replay, supersede replay, no-token HTTP rejection, launch-bound
  MCP caller spoof rejection, SQLite restart persistence and query
  forwarding. It does not contact a model or use an installed daemon profile.

Run with `cargo test --manifest-path crates/native-core/Cargo.toml -j 2 --lib`
and, after a debug build,
`NEURA_NATIVE_DAEMON="$PWD/crates/native-core/target/debug/neura-native-core" node --test tests/native/task-control.test.mjs`.
Actual installed-app metadata and downstream tool-to-language renderers require
checking after the supervisor's authorized release; these fixtures prove the
native descriptions returned to an MCP consumer, not a live session reload.
