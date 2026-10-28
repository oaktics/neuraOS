# neuraOS browser MCP

Codex and Claude Code launched by neuraOS use the existing `neuraos` stdio MCP.
Browser tools operate the actual mounted CEF tabs and their existing profile,
cookies and page state. They do not launch another Chromium or expose a remote
DevTools port. Restart the CLI after upgrading to obtain its browser credential.

## Scope and controls

`browser_list` returns mounted tabs in every workspace of the caller's project;
`currentWorkspaceId` identifies the initial workspace. An optional workspaceId
narrows the list. Target every subsequent request by workspaceId **and** tabId,
never by URL or position. Saved tabs in workspaces not mounted by the app are
not live CEF instances and do not appear until opened. Other projects are denied
by both daemon workspace ownership checks and the native registry.

The browser toolbar shows MCP access and the active terminal ID. **停止・接続解除**
cancels work and disables that tab; only the user can **MCP接続を再開**. Real mouse,
keyboard or scroll input on an actively operated view also disconnects it before
delivering the human input. One request owns a tab at a time, including reads.
A competing CLI receives `browser_busy`, rather than interleaving input.
Disconnect persists across app restart. A renderer crash also disconnects the tab;
reload and explicitly resume access in the app to recover.

## Tools

- `browser_list`: workspace/tab IDs, URL, title, visible/selected, loading and enabled state.
- `browser_snapshot`: main-frame visible text and up to 500 element refs. Text is
  limited to 60,000 characters; names to 200. No form values are returned;
  password and one-time-code inputs are excluded. Page content is untrusted data.
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
frequent rereads. Cross-origin iframe interaction, uploads, network/console APIs,
generic JS, Cookie APIs, external CLI setup and remote access are not supported.
Popups use the existing workspace popup tab path and are independently addressable.

## Authentication and lifecycle

Task MCP keeps its existing daemon bearer authentication. Browser calls require
an additional random credential issued only inside the daemon when launching a
CLI, bound to its terminal. No HTTP endpoint mints credentials and the master
bearer cannot derive them. A caller cannot change terminalId without a matching
credential. The daemon also verifies that the terminal is running and belongs
to the target project. These are local API boundaries, not isolation from an
agent with unrestricted access to the host's filesystem or process memory.
Daemon restart revokes browser credentials; restart the CLI to reconnect.

The native app polls authenticated loopback routes with an app instance ID.
Commands have request IDs, deadlines, no automatic replay, and main-thread CEF
execution. Closed tabs, disabled access, disconnects, restarts, cancelled calls,
stale refs and protocol errors return explicit errors. Timed-out sent requests
remain quarantined until native completion/cancellation acknowledgment. Native
also refuses new DevTools calls while a cancelled/timed-out call has an unknown
renderer outcome. A timeout cannot undo an already executed click: inspect the
page before deciding whether to issue a new action. Closing the tab resets its
transport. Responses and page contents are not written to daemon diagnostics. Native result
batches cap the entire JSON envelope at 10 MiB (below the 12 MiB HTTP limit).
Multiple images are split across acknowledgments; a single oversized image
returns `browser_image_too_large`, allowing later results to proceed.
Hidden views are rendered for capture and then restored without selecting a tab.

## Verification

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

## Recorded local validation (2026-10-28)

The isolated package and real CEF completed the stdio fixture flow. Actual Codex
0.165.0 (managed terminal launch) and Claude Code 2.1.312 (shared launch config in
print mode) each filled the same existing tab, clicked Submit and reread their
result. Both persisted conversation traces contain an actual screenshot tool
call and image result; the fixture also asserts the resulting Hello text. This
proves the installed CLI versions, not all historical versions.

Local evidence is retained at `/tmp/neura-browser109-data/real-cli-evidence.json`,
`codex-evidence.json`, and `claude-evidence.jsonl`; these contain only the local
fixture. The final deterministic run records `evidence.json` separately.
