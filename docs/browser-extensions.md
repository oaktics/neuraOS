# Chromium extensions

neuraOS uses stable CEF 156.0.30 (Chromium 156.0.8078.96). Signing/notarization permits macOS to run the application; it does not enable Chrome extension APIs.

1Password-specific usability is deferred to [Issue #134](https://github.com/oaktics/neuraOS/issues/134)
and is not a release acceptance gate for this general extension foundation.
The extension menu exposes desktop integration setup when 1Password is enabled. Installation,
Connected status and content-script injection do not establish account sync,
saving or filling; see the [setup instructions and investigation](1password-browser.md).

## Using extensions

Workspace browser tabs now use CEF Chrome Views. Use the **puzzle-piece button
in the Chrome address bar** to open an extension, and pin extensions there for
one-click access. Chromium owns action dispatch, popup selection, badges,
`onClicked`, and the normal `activeTab` grant. The popup belongs to the page
where its button was clicked; no page reload or separate-window handoff is
needed. The project controls (pin, split, downloads, and the neuraOS menu)
remain above that address bar.

The previous neuraOS extension-pin preferences are retained but are not copied
into Chromium's private preferences. Pin extensions in the Chrome toolbar.
The old “このポップアップは現在のタブに紐づいていません” document popover is
no longer the action path for workspace browser tabs.

From the neuraOS **⋯** menu:

- **拡張機能を追加・管理…** opens Chromium's extension manager. Use its enable,
  disable, details, remove and Load unpacked controls.
- **Chrome ウェブストアを開く…** opens the official store. Availability and
  compatibility remain subject to Chromium and each extension's requirements.
- **1Password のデスクトップ連携を設定…** remains available when its extension
  is installed. This does not establish real-account save/fill acceptance.
- **このページを拡張対応ウィンドウで開く** is still an explicit option to open
  the URL in a separate, full Chrome-style window. It does not transfer the
  original document, form draft or navigation history.

## Chrome tab hosting

macOS `parent_view` forces CEF Alloy style. Instead of changing extension APIs
or synthesizing permissions, `BrowserChromeTabs.inc` creates a Chrome-style
`CefBrowserView` and frameless `CefWindow`, installs its real Chrome toolbar,
and attaches the native window to the workspace window as an AppKit child.
Its native view is never reparented away from Chromium. Size, position,
visibility and native-sheet presentation follow the host `NCChromiumView`.
Switching tabs hides/shows the same browser instance and preserves drafts.

Each neuraOS page has its own Chrome window identity. Consequently,
`tabs.query({active:true,currentWindow:true})` selects that page in its popup,
but `currentWindow` does **not** enumerate every neuraOS workspace tab as one
Chrome tab strip. Extensions managing whole windows or tab groups need separate
acceptance. Manager, DevTools and extension-created top-level windows remain
outside workspace browser MCP unless explicitly mounted as workspace pages.

Window-opened pages retain their opener and are adopted into the same Chrome
Views hosting path. Keyboard commands and split-pane selection map hosted
native windows back to the owning workspace view. Human input in that window
also cancels browser automation. Extension popups and DevTools retain their
own keyboard context. The shutdown barrier waits for both browser close
callbacks and Views-window destruction before calling `cef_shutdown`.

Chrome tabs, management windows and the legacy Alloy fixtures share the normal
persistent Chromium profile. Chromium handles permission checks; there are no
host grants, API-result patches, MV2 flags or private action calls in the app.
Isolated tests use their own profile and mock keychain.

## Verification

`node scripts/native/chromium/tab-context-probe.mjs` builds a disposable,
ad-hoc-signed app and serves two local fixture pages. At its two prompts, click
**neuraOS Tab Context Probe** in the real Chrome extension toolbar. The fixture
has no host permissions. CDP observes the results; it does not invoke actions
or grant access. The runner writes `evidence.json` and `stderr.log` under the
printed temporary directory and verifies:

- access denied before a click and for the other tab after a click;
- a real `POPUP` context targeting the current page, then a runtime popup
  override and a real `onClicked` event on the second tab;
- input and document state preserved through switching, movement and resize;
- cross-origin navigation revoking the action's temporary access;
- `window.open` retaining opener access and gaining a hosted Chrome context;
- native sheets hiding/restoring surfaces, followed by clean CEF shutdown.

`--lifecycle-only` skips interactive action assertions. It is useful when the
computer display cannot be controlled, but is **not** evidence for action
clicks or successful `activeTab` grants. Neither mode certifies 1Password
account, vault, save/fill, unlock or native messaging behavior.

### Development evidence (2026-11-18)

[Recorded check summary](architecture-evidence/extension-tab-context-2026-11-18.json)
distinguishes the interactive development run from the final lifecycle run.
The interactive run passed real popup/onClicked and per-tab grant assertions
on Chromium 156.0.8078.96. After the popup-adoption and app focus changes,
the final lifecycle run passed window.open/opener, switch/move/resize, sheets
and clean exit. A display-capture failure prevented repeating the interactive
checks and checking the complete workspace UI at that point.

`swift test --package-path apps/macos --build-system native` passed all 238
tests. The native build also passed. The default Xcode build stopped at
SwiftTerm's `CompileMetalFile`; this does not establish a release build.
Real-extension account workflows, integrated browser MCP and installed-app
acceptance remain unverified. No production release was performed.

## Legacy Alloy fixtures

`NCChromiumView(frame:)` and the old extension-document popover remain available
for historical smoke fixtures. Workspace `BrowserModel` opts into Chrome tab
hosting with `initWithFrame:chromeTab:`. The legacy catalog still reads live
`extensions.settings` plus MV3 manifests without modifying preferences, and
validates resource paths against the extension installation. It is not a live
extension-registry or action-dispatch API.

## Historical Alloy behavior (2026-11-17 baseline)

The pre-upgrade baseline used CEF 156.0.7 / Chromium 156.0.8078.17, the bundled MV3 fixture,
an ad-hoc signed `com.neuraos.extensions-test.embedded` bundle, disposable
profile and mock keychain. These results do **not** establish 1Password
account/vault usability; no real sign-in, trust-list change or default-browser
change was performed.

| Probe | Observed result |
| --- | --- |
| Native catalog | Enabled fixture ID, localized/default title, PNG icon and popup URL found; standard Load unpacked installation survives restart |
| Toolbar UI | Fixture icon pin controls, persisted pin after restart, pinned-button popup opening and same-URL Chrome-window handoff exercised in isolated app |
| Native NSPopover document | `chrome-extension://…/popup.html` renders, with `chrome.runtime` and extension APIs available |
| `chrome.runtime.getContexts` | Popover is a `TAB` context with `windowId: -1`, not a Chrome `POPUP` action context |
| `tabs.query({active:true,currentWindow:true})` | Returns the Chrome-style manager's tab, **not** the embedded page |
| `tabs.query({})` | In the diagnostic probe, excludes the embedded page |
| `tabs.get(embeddedId)` | Succeeds; reports `active:false`, `index:-1`, `windowId:-1` |
| `scripting.executeScript` with explicit embedded ID | Succeeds on `127.0.0.1`, covered by the fixture's existing host permission |
| Query-selected tab scripting | Fails with `Cannot access a chrome:// URL` when the separate manager is the active Chrome tab |
| Same embedded ID after navigation to `localhost` | Rejected: extension manifest must request host permission; no synthetic activeTab grant |
| Content script / worker / storage / native messaging | Pass before and after clean CEF shutdown/restart; native host is disposable fixture-only |

An extension that obtains its tab ID through its own content-script messaging
and already has host access can operate on the embedded page. This is a useful
CEF capability, but it does not fix an unmodified extension that relies on
Chrome's active-window query or action-click grant. There is no supported public
CEF call to attach an Alloy tab to Chrome's tab strip or invoke an arbitrary
extension action against it. A deeper solution needs an upstream CEF/Chromium
integration that preserves browser-window association and normal permission
semantics; patching JavaScript API results or granting permissions in the host
would not be a sound substitute. The explicit same-URL Chrome-window handoff was the mitigation for that
Alloy-only implementation. Workspace pages now use the Chrome Views path above.

1Password (`aeblfdkhhhdcdjpifhhbdiojplfjncoa`) can be enumerated like any installed
MV3 extension with a declared action, but its real popup, native messaging trust,
account-ready, save/fill and unlock behavior were not tested in this change.
[Issue #134](https://github.com/oaktics/neuraOS/issues/134) remains open.

## Reproducible isolated verification

```sh
NEURA_SIGN_IDENTITY=- NEURA_APP_ID=com.neuraos.extensions-test \
  NEURA_DEV_DATA_DIR=/tmp/neura-extensions-dev NEURA_DEV_PORT=44329 pnpm build
node scripts/native/chromium/extensions-smoke.mjs
```

The test entry point refuses production bundle IDs, uses an isolated profile and mock keychain, and never starts the daemon. Only that entry point exposes a loopback DevTools port and enables extension debugging for the local fixture. On the first run, select the printed sample directory in Chromium's native Load unpacked chooser (the harness waits 90 seconds); later runs reuse it. The ordinary UI installation is deliberate: CDP `Extensions.loadUnpacked` alone is a temporary installation and cannot prove persistence. The test records evidence in its temporary profile directory, verifies MV3 execution in an embedded tab, shuts CEF down, and reopens the same profile without reinstalling. The bundled [sample](../tests/fixtures/chromium-extension) includes an action icon
and popup. The harness now asks the native fixture to open the actual NSPopover,
waits for its extension context to load, and records catalog, context, tab-query,
explicit-ID scripting and ungranted-host results in `evidence.json`. Both phases
assert clean shutdown, with a popover still open. `NEURA_EXTENSION_TEST_HOLD=1`
pauses each phase for UI inspection; create `continue` in the printed isolated
data directory to resume. The fixture also mounts the production toolbar for pin/menu testing, without
registering a BrowserModel or MCP tab. Pins belong to the isolated test bundle. See [Chrome's unpacked-extension guide](https://developer.chrome.com/docs/extensions/get-started/tutorial/hello-world) for the native management workflow.

## Extension Origin regression

CEF 156.0.7's extension Origin synthesis was fixed upstream in #4309. We pin
stable 156.0.30, which contains `3d34cc3` (see [root cause and evidence](1password-browser.md)).
The official arm64/x64 archive checksums live in `scripts/native/chromium/version.json`.
Preparation, bundling and both CEF/Swift CI cache keys already consume that
manifest; changing it invalidates the caches. C API headers/hash are rebuilt
from the new SDK. Helper bundles, sandbox and signing layout are unchanged.

```sh
NEURA_APP_OUTPUT=/path/to/isolated-extensions-test.app \
  NEURA_ORIGIN_CHROME='/path/to/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing' \
  node scripts/native/chromium/extension-origin-smoke.mjs
```

This automated probe requires a `com.neuraos.extensions-test…` bundle. It loads
only `tests/fixtures/chromium-extension-origin` temporarily via CDP; Chrome uses
`--load-extension` and a fresh user-data-dir. It opens the test Chrome app to
activate its popup. Each browser gets a separate disposable profile and mock
keychain. The server listens only on loopback. Evidence contains received
Origin/Sec-Fetch headers, never credentials. `--diagnostic` records a broken
baseline without enforcing Origin assertions. Default mode asserts that SW,
popup and tab POSTs send `chrome-extension://<id>`, that ungranted CORS requests
also preserve the origin, and that granted GETs never send literal `null`.
An absent Origin on a granted GET is normal Chromium behavior. This probe does
not replace the two-phase installed-extension persistence smoke above.

## External pump and host architecture

CEF work is requested through `on_schedule_message_pump_work`, marshalled/coalesced onto the AppKit thread and scheduled with a replaceable one-shot timer. With no pending work the fallback is 33ms, matching the [pinned official CEF example](https://github.com/chromiumembedded/cef/blob/6028375/tests/shared/browser/main_message_loop_external_pump.cc). Zero-delay requests yield to AppKit; nested calls are deferred. Native menu tracking and neuraOS sheets retain their reentry protection. Chrome-owned install/permission sheets keep pumping so their controls remain usable.

Run `node scripts/native/chromium/pump-smoke.mjs` with the isolated test bundle to compare the old repeating 10ms baseline and adaptive mode. Each run discards two seconds of warmup and records ten seconds of process CPU time, actual pump wakes, blocked calls and reentries. These are application-process measurements, not total system/renderer/GPU energy measurements.

Decision: retain CEF's native windowed surface in the UI process. Renderer, GPU and utility processes already run separately under Chromium's sandbox. A separate browser host would need a new cross-process surface/input/lifecycle bridge; macOS offscreen/parent-view paths force Alloy and do not provide the Chrome toolbar/window needed here. No measured benefit justifies that extra integration and extension risk in this change. A separate-host prototype was not benchmarked; no claim of comparative speedup is made.

Observed on the development Mac (two alternating pairs, same Developer ID test binary, approximately ten seconds each):

| Mode | Pump timer wakes | App CPU seconds | Nested work calls |
| --- | --- | --- | --- |
| Old repeating 10ms, run 1 | 384 | 0.312 | 0 |
| Adaptive, run 1 | 169 | 0.253 | 0 |
| Old repeating 10ms, run 2 | 389 | 0.426 | 0 |
| Adaptive, run 2 | 218 | 0.391 | 0 |

Actual timer delivery is affected by macOS coalescing and other work. The observed aggregate wake reduction is about 50%; CPU reduction varied from 8% to 19%. This short idle probe does not establish interactive latency or whole-machine power savings. Direct UI checks also covered native sheet Cancel, native input context-menu dismissal and subsequent editing, and Chrome extension-removal Cancel. The official Store installation permission sheet was exercised separately.

## Browser MCP regression against a native daemon

The extension/pump fixtures above do not start a daemon. The separate
`scripts/native/chromium/browser-smoke.ts` can test an external daemon through
its public API and the MCP configuration delivered by a legitimate Claude
terminal launch:

```sh
NEURA_BROWSER_SMOKE_DAEMON=/absolute/path/to/neura-native-core \
  NEURA_DEV_DATA_DIR=/tmp/neura-browser-native-smoke \
  NEURA_DEV_PORT=44359 NEURA_APP_OUTPUT=/path/to/browser-fixture.app \
  pnpm exec tsx scripts/native/chromium/browser-smoke.ts
```

Build the browser fixture with a `com.neuraos.browser-smoke.*` bundle ID and
matching `NEURA_DEV_DATA_DIR` / `NEURA_DEV_PORT`, as required by `BrowserFixture`.
The native executable receives those environment variables. Optional
`NEURA_BROWSER_SMOKE_DAEMON_ARGS` is a JSON string array, not shell text.

External mode creates only disposable project/workspaces through public
commands, starts a fixture Claude via `terminal.open`, captures its own scoped
browser credential in a mode-0600 file, and launches the exact MCP command/args
from that session's configuration. The fixture provider only answers capability
probes and waits; it never starts real Claude or accesses an account. The capture
is removed during cleanup. No production credential endpoint or direct Store
write is needed in external mode. Legacy in-process comparison (and optional
real-CLI testing) remains available by omitting the external-daemon variable;
real-CLI mode is explicitly rejected with external mode.

External mode cannot collect the old Fastify `onSend` transport timing hook;
its evidence marks that limitation and retains all browser behavior assertions.
The external launch path was first checked against the Node daemon in a child
process; run it against the finished Rust executable and integrated native app
before treating native-daemon compatibility as verified.
