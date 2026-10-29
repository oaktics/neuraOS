# 1Password in neuraOS: setup and verification boundary

The extension windows are an enabling change, not certification that 1Password autofill, saving or desktop unlocking works in neuraOS. Do not infer 1Password compatibility from the sample extension or from macOS notarization.

## Official requirements

1. Install the official [1Password extension](https://chromewebstore.google.com/detail/1password---password-mana/aeblfdkhhhdcdjpifhhbdiojplfjncoa) from Chrome Web Store in the extension window. Its stable extension ID is `aeblfdkhhhdcdjpifhhbdiojplfjncoa`.
2. For desktop integration, 1Password requires the browser's code signature, extension ID and native messaging host to validate. See [connection security](https://support.1password.com/1password-browser-security/).
3. For a custom Mac browser, the user must unlock 1Password, open **Settings > Browser > Add Browser**, and select the signed app in Applications. See [additional browsers](https://support.1password.com/additional-browsers/) and [signature troubleshooting](https://support.1password.com/code-signature/). Signing the app does not automatically add this trust.
4. Chromium must be able to find the official native messaging manifest. [Chromium's documentation](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging) places user-level manifests under the browser user data directory's `NativeMessagingHosts`. [CEF's pinned source](https://github.com/chromiumembedded/cef/blob/47dbc1d/libcef/common/resource_util.cc) maps that directory to `root_cache_path`; in neuraOS this is `<NeuraDataDirectory>/Chromium`, normally `~/Library/Application Support/neuraOS/Chromium`. A manifest installed for Google Chrome is not automatically installed in that separate directory.

neuraOS does not change 1Password trust settings, copy vault data, impersonate another browser, or bypass signature/native messaging validation. The verification bundle uses the same Developer ID team as neuraOS, a different bundle ID, a disposable profile and mock keychain. No real vault was authenticated.

## User verification after installing an approved signed build

These steps require the user's trust decision and an unlocked desktop app. The isolated observations below do not prove the in-progress real desktop connection:

- Install the official extension through the puzzle-piece menu's dedicated window. Check the publisher and extension ID.
- Choose **1Password を設定… > デスクトップ連携を準備**. This verifies the installed official helper signature (AgileBits team `2BUA8C4S2C`, identifier `com.1password.browser-support`) and registers its standard stdio host manifest in this CEF profile only. It permits only the official stable extension ID, refuses conflicting existing registrations and does not edit another browser. Then follow the additional-browser steps above and reload the extension. Check whether it reports the desktop app as connected; if not, collect a 1Password diagnostic without weakening validation.
- Unlock 1Password for Mac and complete **Settings > Browser > Add Browser** for the signed app. The [official additional-browser flow](https://support.1password.com/additional-browsers/) can add the desktop app's accounts to the extension automatically; a separate website login is not a prerequisite. Confirm the extension reports a desktop connection and unlocks before testing a vault.
- In an isolated test vault, create a disposable login for a test page. Verify inline suggestions and fill in an embedded neuraOS tab, then repeat in the dedicated window. Verify saving a changed/new test login and locking/unlocking. No real credentials are needed for this acceptance test.
- Close and restart neuraOS, confirm installation persists, and repeat fill/unlock. If embedded Alloy behavior fails, use the dedicated window; if that fails, use an officially supported external browser.

The dedicated window is outside browser MCP. Embedded tabs remain automatable: users should disconnect MCP for tabs that contain vault-filled data. Trusting a custom browser grants access to data while 1Password is unlocked, as described by 1Password's guidance.

## Observed in the isolated test (2026-10-29)

- Official Web Store permission sheet completed and Chromium reported the extension added; version 8.12.42.36 (MV3), original stable ID. The Store's generic “switch to Chrome” banner did not prevent installation.
- After process shutdown/restart, the manager displayed 1Password enabled. Opening its toolbar action led to its own setup/sign-in page. No account was entered.
- The shipped setup view successfully verified the official helper and wrote its standard host registration to the disposable profile. No real 1Password trust setting was changed.
- In an embedded Alloy test form, the input accessibility tree offered the 1Password menu after typing a dummy username. CDP observed the official `inline/inject-content-scripts.js`, `inline/injected.js` and extension isolated execution context. This proves injection, **not** credential suggestions or autofill.
- A separate sample MV3 extension executed content → service worker → persistent storage across restart and round-tripped to a disposable native host through CEF's standard profile manifest search path. This proves the native messaging transport, **not** 1Password trust acceptance.

Remaining acceptance gates are actual 1Password desktop connection, unlock/lock, suggestions, filling, saving a new/changed test login, and authenticated restart. They require desktop unlock and explicit custom-browser trust. A Connected indication after the user adds the browser has been reported, but account sync and authenticated fill/save success remain unverified; see the dated acceptance status below. An unsupported extension API has not been identified as a blocker for these gates. APIs requiring full Chrome tab/window UI remain limited to the dedicated window; the embedded tab alone cannot supply the toolbar popup.

These extension observations are independent of the Rust daemon migration. Native daemon protocol/Swift UI fixtures, signed and notarized release publication, installation/rollback on the real app, and authenticated 1Password acceptance must be recorded separately. Neither a release nor a browser MCP fixture authenticates a vault.

## Desktop acceptance in progress (2026-10-29)

The integration coordinator reports a Connected indication after the user's
additional-browser registration, but this does not establish account sync,
unlock, saving or filling. The popup remains at its logo; the official remote
overview returned HTTP 500 during investigation. These observations do not yet
prove a single root cause. The local fixture CSP was adjusted and is being
retested; authenticated acceptance remains incomplete.

Bundle Info.plist normalization has been fixed before signing. The coordinator
reports status 0 for main/helper raw and Foundation-serialized dynamic signature
checks. This removes the observed signature-validation failure, not the remaining
popup or vault acceptance gates. See [signing scope](macos-signing.md).
