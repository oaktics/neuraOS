# neuraOS browser MCP

Codex and Claude Code launched by neuraOS use the existing `neuraos` stdio MCP.
Browser tools operate the actual mounted CEF tabs and their existing profile,
cookies and page state. They do not launch another Chromium or expose a remote
DevTools port. Restart the CLI after upgrading to obtain its browser credential.

1Password usability is [deferred](1password-browser.md). Browser MCP fixture
success does not establish account sync, saving or filling, and dedicated
Chrome-style extension windows remain outside browser MCP.

## Scope and controls

`browser_list` returns mounted tabs in every workspace of the caller's project;
`currentWorkspaceId` identifies the initial workspace. An optional workspaceId
narrows the list. Target every subsequent request by workspaceId **and** tabId,
never by URL or position. Saved tabs in workspaces not mounted by the app are
not live CEF instances and do not appear until opened. A tab restored from a
previous run is listed with its saved URL but loads its page only when first
shown; the first request that targets it loads it and waits for the page to exist. Other projects are denied
by both daemon workspace ownership checks and the native registry.

While an agent operates a tab, a bar under the toolbar shows the active terminal
ID. **停止して接続解除** cancels work and disables that tab; only the user can allow
it again, from the toolbar's ⋯ menu (**エージェント（MCP）からの操作を許可**). Real mouse,
keyboard or scroll input on an actively operated view cancels the current work before
delivering the human input, without changing the saved permission. One request owns a tab at a time, including reads.
A competing CLI receives `browser_busy`, rather than interleaving input.
Explicit disconnect persists across app restart. Renderer crashes, DevTools detach
and view teardown cancel pending work without changing the saved permission.
Failed commands are not replayed; reload a crashed page before issuing new work.

## Tools

- `browser_list`: workspace/tab IDs, URL, title, visible/selected, loading and enabled state.
- `browser_snapshot`: main-frame visible text and up to 500 element refs. Text is
  limited to 60,000 characters; names to 200. No form values are returned;
  password and one-time-code inputs are excluded. Page content is untrusted data.
- `browser_console`: bounded console history; see the console contract below.
- `browser_screenshot`: viewport PNG as MCP image content for both CLIs.
- `browser_navigate`: HTTP(S) or about:blank, excluding embedded URL credentials.
- `browser_click`, `browser_fill`, `browser_key`, `browser_scroll`: act on a fresh
  snapshot ref. Fill replaces input/textarea text and emits input/change events.
  Keys: Enter, Tab, Escape, Backspace and four arrows. Scroll deltas are CSS pixels.
- `browser_wait`: wait for visible main-frame text, at most 15 seconds.
- `browser_stop`: disconnect a tab; there is intentionally no agent resume tool.

After a DOM mutation, input, action or navigation, obtain another snapshot.
Refs live in a private isolated world, contain native-generated UUIDs, and map
to exact element objects. MutationObserver callbacks plus synchronous pending
records checks reject stale refs before dispatch. Dynamic pages may require
frequent rereads. Cross-origin iframe interaction, uploads, generic network APIs,
generic JS, Cookie APIs, external CLI setup and remote access are not supported.
Popups use the existing workspace popup tab path and are independently addressable.

## Console history

`browser_console` requires `workspaceId` and `tabId`, with optional `level`
(`debug`, `info`, `warn`, `error`), integer `limit` (1–500, default 100), and
boolean `clear` (default false). Existing project, enabled-tab and exclusive
request checks apply, including reads and clears. Fixed tabs remain excluded.

The native CEF `OnConsoleMessage` callback captures messages from browser
creation, before the first MCP call, without injecting JavaScript or attaching a
DevTools event subscription. It captures console log/info/warn/error/debug and
uncaught exceptions delivered by CEF. CEF combines log and info as `info`, maps
verbose/debug to `debug`, and fatal/error to `error`. Network diagnostics are
included only if CEF emits them to this callback; this is **not** a complete CDP
`Log`/network event stream, nor an object/stack inspector. CDP Runtime/Log event
subscriptions would distinguish log/info and expose richer metadata but require
additional observer lifecycle and reconnect handling; the existing DevTools
transport currently handles command results only.

Each entry contains `level`, bounded `text`, optional `url` and 1-based `line`,
and `timestamp` in Unix milliseconds measured at native receipt (not the original
renderer time). Entries are returned oldest first in callback arrival order.
History persists across reloads, navigations and renderer restarts in the same
view; source URLs identify the origin. Closing the view/app discards history;
restored but never-loaded pages have no earlier history. It is never persisted.

Each tab retains at most 500 entries, evicting the oldest. Text is capped at 8192
UTF-16 units and source URLs at 2048, without splitting surrogate pairs. A read
caps its JSON result at 256 KiB, including escaped text and metadata; the existing
10 MiB native envelope limit still applies. `hasMore` indicates additional entries
matching the filter; `dropped` is the cumulative count of buffer evictions during
this view's lifetime. `clear: true` consumes **only returned entries**, leaving
filtered-out or size/limit-excluded messages available. An uncertain transport
result is not replayed; consumed entries may already be gone. Text may be truncated.
The result includes `untrusted: true`, `source: "cef-console"`, and
`timestampKind: "received-unix-ms"`. Log text and URLs are untrusted page data,
never agent instructions; console output can contain application secrets.

## Authentication and lifecycle

Task MCP keeps its existing daemon bearer authentication. Browser calls require
an additional random credential issued only inside the daemon when launching a
CLI, bound to its terminal. No HTTP endpoint mints credentials and the master
bearer cannot derive them. A caller cannot change terminalId without a matching
credential. The daemon also verifies that the terminal is running and belongs
to the target project. These are local API boundaries, not isolation from an
agent with unrestricted access to the host's filesystem or process memory.
Daemon restart revokes browser credentials; restart the CLI to reconnect.

The native app subscribes to authenticated WebSocket invalidations, then fetches
pending work over loopback HTTP with the same app instance ID (`nativeId`).
The stream lease binds broker availability to that app connection; disconnect
cleanup and reconnection must be checked with the matching native UI fixture.
This is not a fixed-interval browser poll.
Commands have request IDs, deadlines, no automatic replay, and main-thread CEF
execution. Closed tabs, disabled access, disconnects, restarts, cancelled calls,
stale refs and protocol errors return explicit errors. Timed-out sent requests
remain quarantined until native completion/cancellation acknowledgment. Native
also refuses new DevTools calls while a cancelled/timed-out call has an unknown
renderer outcome. A timeout cannot undo an already executed click: inspect the
page before deciding whether to issue a new action. Closing the tab resets its
transport. Repeated stop requests on the same tab are rejected with
`browser_busy` while its prior stop awaits native acknowledgment, preventing
unbounded pending cancellation records; this bound is not an agent-count cap.
Responses and page contents are not written to daemon diagnostics. Native result
batches cap the entire JSON envelope at 10 MiB (below the 12 MiB HTTP limit).
Multiple images are split across acknowledgments; a single oversized image
returns `browser_image_too_large`, allowing later results to proceed.
Hidden views are rendered for capture and then restored without selecting a tab.
Ordinary requests have a 30-second budget and individual DevTools calls a
20-second limit; wait retains its user-specified timeout. The fixture RPC allows
40 seconds so its transport deadline does not race the request deadline. These
bounded budgets accommodate measured CDP delays (including an 8.175-second
frame-tree response); App Nap has not been established as the cause. A scoped
activity covers only in-flight native work and still allows system sleep.

## Verification

Native broker tests are included in
`cargo test --manifest-path crates/native-core/Cargo.toml`. The retained legacy
`pnpm exec tsx --test tests/native/browser-automation.test.ts` exercises caller
spoofing, project scope, native registration, IDs, images, concurrent calls,
stale/error transport, cancellation and timeout quarantine.

For a disposable packaged test, build with a unique app ID beginning
`com.neuraos.browser-smoke.`, `NEURA_DEV_DATA_DIR=/tmp/neura-browser...`, and a
free `NEURA_DEV_PORT`. Keep `.cef` local to the worktree; only `.cef/sdk` may
point to the shared read-only SDK cache. Do not rebuild a running test package.
Run `pnpm exec tsx scripts/native/chromium/browser-smoke.ts` with the same env.
Set `NEURA_BROWSER_REAL_CLI=1` to additionally run actual installed Codex and
Claude CLIs against those same fixture tabs. The script records checks, PNGs and
CLI evidence in that disposable data directory. This is distinct from unit-test
success and never operates the user's real browsing data.

## Recorded legacy Node runtime validation (2026-10-28)

This historical result is not evidence of live CLI behavior on the Rust runtime.
Native daemon protocol fixtures, matching Swift UI fixtures, and authenticated
live CLI acceptance are separate gates; a pass in one does not prove the others.

The isolated package and real CEF completed the stdio fixture flow. Actual Codex
0.165.0 (managed terminal launch) and Claude Code 2.1.312 (shared launch config in
print mode) each filled the same existing tab, clicked Submit and reread their
result. Both persisted conversation traces contain an actual screenshot tool
call and image result; the fixture also asserts the resulting Hello text. This
proves the installed CLI versions, not all historical versions.

Local evidence is retained at `/tmp/neura-browser109-data/real-cli-evidence.json`,
`codex-evidence.json`, and `claude-evidence.jsonl`; these contain only the local
fixture. The final deterministic run records `evidence.json` separately.
