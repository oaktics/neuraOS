# Chromium extensions

neuraOS uses stable CEF 156.0.30 (Chromium 156.0.8078.96). Signing/notarization permits macOS to run the application; it does not enable Chrome extension APIs.

1Password-specific usability is deferred to [Issue #134](https://github.com/oaktics/neuraOS/issues/134)
and is not a release acceptance gate for this general extension foundation.
The extension menu exposes desktop integration setup when 1Password is enabled. Installation,
Connected status and content-script injection do not establish account sync,
saving or filling; see the [setup instructions and investigation](1password-browser.md).

## Using extensions

Open the puzzle-piece menu beside the browser address field. Enabled MV3
extensions appear with their manifest icon and localized title; use **ピン留め**
to keep an icon beside the address field. Pins are neuraOS preferences, shared
across workspace toolbars and retained across restarts (separate from Chrome's
own pin list). Clicking an icon or extension menu item opens its declared popup
in an anchored native popover on the same Chromium profile.

**This is an extension document, not a Chrome action invocation.** The popover
is not associated with the embedded tab. An extension querying the active tab
can target a different Chrome-style window, even while the embedded tab has
focus. The popover labels this limitation and offers **このページを拡張対応ウィンドウで開く**.
Use that window's real Chrome action when the extension needs the current page,
`activeTab`, or an action without a declared popup. The handoff opens the URL;
it does not move the original document, unsaved form state or its history.

Management remains in Chromium's own UI:

- **拡張機能を追加・管理…** opens Chromium's extension manager in a separate neuraOS window. Use its enable/disable, reload, details and remove controls.
- For an unpacked extension, turn on Developer mode in that manager, choose Load unpacked, and select the folder containing `manifest.json`. Keep that folder in place: Chromium loads its files there on subsequent launches.
- **Chrome ウェブストアを開く…** opens the official store in the same window style. Installation availability depends on the extension and the store's Chromium support; this is not a promise of Chrome compatibility.
- **このページを拡張対応ウィンドウで開く** opens the current URL with Chromium's full toolbar. Use the puzzle-piece menu there to pin extensions and open their popups.

The windows share the existing Chromium profile with embedded tabs, across workspaces. Installation and grants therefore apply to that profile, not just the current workspace. Review Chromium's permission prompts. The separate windows are not workspace tabs and are not exposed through neuraOS browser MCP. Downloads there use Chromium's UI; embedded tabs retain neuraOS's downloads UI.

## Why retain a separate window?

Embedded macOS NSViews force CEF's Alloy style. The [CEF window-info definition](https://github.com/chromiumembedded/cef/blob/6028375/include/internal/cef_types_mac.h) documents this restriction. The [CEF maintainer's extension guidance](https://github.com/chromiumembedded/cef/issues/3859) distinguishes profile-level extension features from Chrome UI features and directs embedders to use a Chrome-style window for `chrome://extensions`. [CEF #3763](https://github.com/chromiumembedded/cef/issues/3763) explains the related WebUI restrictions.

The existing embedded view, popup handling, browser MCP and download callbacks remain Alloy style. The new top-level Chrome windows use the same default request context and persistent `Chromium/Default` profile. Their tabs, popups and default-client windows participate in the existing CEF shutdown barrier.

## Compatibility boundaries

- Manifest V3 is the target. Content scripts, runtime messaging, service workers and `storage.local` are covered by the bundled sample. This does not certify every extension/API.
- Manifest-declared popup documents can run in the embedded toolbar popover. Chrome action invocation, dynamic per-tab action state, badges, `onClicked`, and active-tab/window semantics still require the separate Chrome-style window. Embedded tabs do not become Chrome window tabs.
- Google account sync, `identity` OAuth, vendor-specific native messaging trust, enterprise policy extensions, DRM and paid/store-restricted extensions are not validated. A supported external Chrome browser remains the alternative for extensions that require those integrations.
- Manifest V2 is not a supported target. No compatibility flags, permission bypasses, CRX download workarounds or Chromium security overrides are added to the normal app.
- Unpacked files are not copied or automatically updated. Use Chromium's reload control after updating them, or the publisher's official distribution when available.

## Native catalog and popup implementation

The pinned CEF 156.0.30 SDK has no `CefExtension`/`GetExtensions`/`GetExtension` or
extension-action dispatch API. Its `cef_request_context_t` inherits the public
`cef_preference_manager_t`, however. neuraOS reads a **copy of the live global
request context's `extensions.settings` preference** using `get_preference`,
and reads the installation's manifest, locale messages and icon files. This
avoids stale on-disk `Preferences`/`Secure Preferences` snapshots and never
writes either file. Chromium 156 treats missing/empty `disable_reasons` as
enabled; the catalog also excludes disabled and blocklisted entries. The
preference schema is Chromium implementation detail and must be rechecked
when upgrading CEF. It is not a live extension-registry API: an enabled entry
can still fail to load, and Chromium remains responsible for permission checks.

Only MV3 entries are listed. Declared title/popup/icon defaults are supported,
including locale fallback, unpacked installations and installed version paths.
Dynamic `chrome.action.setPopup/setTitle/setIcon`, badges and per-tab overrides
are not reflected. Resource resolution rejects escapes outside an installation,
including symlinks. Visible toolbars refresh every three seconds and when the
menu opens; opening an action rechecks the live catalog. No extension bindings,
active-tab IDs, permission overrides or Chrome-private action calls are injected.

The popover uses `NCChromiumView`, the global request context, and the existing
Alloy lifecycle/download callbacks. It is outside browser MCP's registered tab
list. CEF's native auto-resize callback sizes its content within 400–600 ×
100–600 points, plus the fallback footer. Dismissal closes its CEF browser;
normal tabs, popup children, Chrome windows and these popovers all participate
in the same shutdown barrier. Normal tab sizing and the external pump are
unchanged.

## Measured embedded behavior (2026-11-17 baseline)

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
would not be a sound substitute. The explicit same-URL Chrome-window handoff is
the supported mitigation here.

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
