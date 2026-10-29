# Chromium extensions

neuraOS uses CEF 156.0.7 (Chromium 156.0.8078.17). Signing/notarization permits macOS to run the application; it does not enable Chrome extension APIs.

## Using extensions

Open the puzzle-piece menu beside the browser address field:

- **拡張機能を追加・管理…** opens Chromium's extension manager in a separate neuraOS window. Use its enable/disable, reload, details and remove controls.
- For an unpacked extension, turn on Developer mode in that manager, choose Load unpacked, and select the folder containing `manifest.json`. Keep that folder in place: Chromium loads its files there on subsequent launches.
- **Chrome ウェブストアを開く…** opens the official store in the same window style. Installation availability depends on the extension and the store's Chromium support; this is not a promise of Chrome compatibility.
- **このページを拡張対応ウィンドウで開く** opens the current URL with Chromium's full toolbar. Use the puzzle-piece menu there to pin extensions and open their popups.

The windows share the existing Chromium profile with embedded tabs, across workspaces. Installation and grants therefore apply to that profile, not just the current workspace. Review Chromium's permission prompts. The separate windows are not workspace tabs and are not exposed through neuraOS browser MCP. Downloads there use Chromium's UI; embedded tabs retain neuraOS's downloads UI.

## Why a separate window?

Embedded macOS NSViews force CEF's Alloy style. The [CEF window-info definition](https://github.com/chromiumembedded/cef/blob/47dbc1d/include/internal/cef_types_mac.h) documents this restriction. The [CEF maintainer's extension guidance](https://github.com/chromiumembedded/cef/issues/3859) distinguishes profile-level extension features from Chrome UI features and directs embedders to use a Chrome-style window for `chrome://extensions`. [CEF #3763](https://github.com/chromiumembedded/cef/issues/3763) explains the related WebUI restrictions.

The existing embedded view, popup handling, browser MCP and download callbacks remain Alloy style. The new top-level Chrome windows use the same default request context and persistent `Chromium/Default` profile. Their tabs, popups and default-client windows participate in the existing CEF shutdown barrier.

## Compatibility boundaries

- Manifest V3 is the target. Content scripts, runtime messaging, service workers and `storage.local` are covered by the bundled sample. This does not certify every extension/API.
- Toolbar actions/popups and APIs depending on a Chrome window or active tab should be used in the separate window. Embedded Alloy tabs do not acquire a Chrome toolbar or full `tabs`/`windows` UI semantics.
- Google account sync, `identity` OAuth, vendor-specific native messaging trust, enterprise policy extensions, DRM and paid/store-restricted extensions are not validated. A supported external Chrome browser remains the alternative for extensions that require those integrations.
- Manifest V2 is not a supported target. No compatibility flags, permission bypasses, CRX download workarounds or Chromium security overrides are added to the normal app.
- Unpacked files are not copied or automatically updated. Use Chromium's reload control after updating them, or the publisher's official distribution when available.

## Reproducible isolated verification

```sh
NEURA_SIGN_IDENTITY=- NEURA_APP_ID=com.neuraos.extensions-test \
  NEURA_DEV_DATA_DIR=/tmp/neura-extensions-dev NEURA_DEV_PORT=44329 pnpm build
node scripts/native/chromium/extensions-smoke.mjs
```

The test entry point refuses production bundle IDs, uses an isolated profile and mock keychain, and never starts the daemon. Only that entry point exposes a loopback DevTools port and enables extension debugging for the local fixture. On the first run, select the printed sample directory in Chromium's native Load unpacked chooser (the harness waits 90 seconds); later runs reuse it. The ordinary UI installation is deliberate: CDP `Extensions.loadUnpacked` alone is a temporary installation and cannot prove persistence. The test records evidence in its temporary profile directory, verifies MV3 execution in an embedded tab, shuts CEF down, and reopens the same profile without reinstalling. The bundled [sample](../tests/fixtures/chromium-extension) also has an action popup for manual `activeTab`/`scripting` verification. See [Chrome's unpacked-extension guide](https://developer.chrome.com/docs/extensions/get-started/tutorial/hello-world) for the native management workflow.

## External pump and host architecture

CEF work is requested through `on_schedule_message_pump_work`, marshalled/coalesced onto the AppKit thread and scheduled with a replaceable one-shot timer. With no pending work the fallback is 33ms, matching the [pinned official CEF example](https://github.com/chromiumembedded/cef/blob/47dbc1d/tests/shared/browser/main_message_loop_external_pump.cc). Zero-delay requests yield to AppKit; nested calls are deferred. Native menu tracking and neuraOS sheets retain their reentry protection. Chrome-owned install/permission sheets keep pumping so their controls remain usable.

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
