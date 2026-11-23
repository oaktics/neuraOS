# 1Password in neuraOS

Account-ready, embedded save/fill, unlock/re-lock and restart acceptance remain
tracked in [Issue #134](https://github.com/oaktics/neuraOS/issues/134). Registering
the native host and passing the account-free Origin probe do not certify those
real-account workflows.

## Desktop integration setup

Install or reinstall the official 1Password MV3 extension through the neuraOS
toolbar menu → **拡張機能** → **Chrome ウェブストアを開く…**. Enable it through
**拡張機能を追加・管理…** (`chrome://extensions`). These dedicated Chrome-style
windows are retained because installation in an ordinary workspace tab has not
been verified.

With the extension enabled, open the neuraOS toolbar menu → **拡張機能** →
**1Password のデスクトップ連携を設定…** →
**デスクトップ連携を準備**. The app verifies the official helper's Apple-anchored
signature, identifier and team before registering it. An identical existing
manifest is success; a differing file is never overwritten, and profile/host
folder/manifest symlinks are rejected.

Use Chrome's puzzle-piece button beside the address field for the extension
action popup after setup.

Registration is at `<data>/Chromium/NativeMessagingHosts/com.1password.1password.json`,
where `<data>/Chromium` is `NCChromiumProfileDirectory()` (Chromium's user-data-dir),
**not** its `Default` child. Only this browser's host manifest is written. The
1Password trust list, accounts and other browsers' profiles are never changed.
If necessary, the user adds the signed neuraOS app in 1Password → Settings →
Browser → Add Browser, then reloads the extension. Existing trust need not be
registered again. See the official [additional-browser procedure](https://support.1password.com/additional-browsers/).

## Root cause and fix (2026-11-17)

The production observations supplied by the user identify two independent
failures. First, removing the setup menu left the native messaging manifest
missing; manual registration at the user-data-dir level restored the signed
helper connection and desktop account delegation. Second, granted extension
fetches carried the literal header `Origin: null` and the account API returned
500. Those production observations are user-reported, not a real-account test
performed by this change.

The second failure is [CEF #4309](https://github.com/chromiumembedded/cef/issues/4309).
CEF's `InterceptedRequest::Restart()` synthesized Origin by running an extension
initiator through `Referrer::SanitizeOriginForRequest`. `chrome-extension` is not
a referrer scheme, so this produced an opaque origin. This was not a missing
neuraOS scheme registration, helper setting or host permission. neuraOS has no
Origin rewrite or custom extension-scheme registration.

The pinned SDK is now **stable CEF 156.0.30+g6028375, Chromium 156.0.8078.96**,
for arm64 and x64, using the official Spotify build manifest checksums. The
[build history comparison](https://github.com/chromiumembedded/cef/compare/3d34cc3...6028375)
is ahead by 17 commits and behind by zero: fix
[`3d34cc3f7cbf30088e085eaa1b63089c9dba06a1`](https://github.com/chromiumembedded/cef/commit/3d34cc3f7cbf30088e085eaa1b63089c9dba06a1)
is an ancestor. The fix leaves extension Origin generation to Chromium's network
service, preserving normal permission/CORS handling. No header spoofing,
permission override, disabled web security or application-side backport is used.

### Account-free comparison

`extension-origin-smoke.mjs` loads a minimal MV3 extension into throwaway
profiles and captures only Origin and Sec-Fetch metadata at a loopback echo
server. It covers the service worker, actual action popup (Chrome) / native
popover (neuraOS), and an extension tab, with GET and POST to granted 127.0.0.1
and ungranted localhost. No 1Password account, host, trust list or service is used.

Baseline [header captures](architecture-evidence/extension-origin-156.0.7.json)
show CEF 156.0.7 sends literal `"null"` for granted GET and POST in all three
contexts. Chrome for Testing **153.0.8010.12**, the installed comparison binary,
omits Origin for granted GET and sends `chrome-extension://<id>` for POST.
Both send the extension origin for ungranted CORS requests. JSON `null` in the
evidence means the header is absent; the string `"null"` means the faulty header.
The Chrome version differs from CEF and is recorded explicitly.

The [156.0.30 captures](architecture-evidence/extension-origin-156.0.30.json)
match the comparison Chrome in all 12 cases (three contexts × two hosts × two
methods), including Sec-Fetch metadata. Granted requests use `Sec-Fetch-Site:
none`, ungranted requests `cross-site`, and all use mode `cors`, destination
`empty`. Thus `Sec-Fetch-Site: none` alone was not the defect. No C API/struct
adaptation was needed for this stable patch upgrade.

| Browser | Granted GET Origin | Granted POST Origin | Ungranted GET/POST Origin |
| --- | --- | --- | --- |
| Chrome for Testing 153.0.8010.12 | absent | extension origin | extension origin |
| neuraOS / CEF 156.0.7 | literal `null` | literal `null` | extension origin |
| neuraOS / CEF 156.0.30 | absent | extension origin | extension origin |

### Upgrade regression verification

The [sanitized verification record](architecture-evidence/cef-156.0.30-verification.json)
covers local macOS arm64 runs:

- `swift test --package-path apps/macos`: 205 passed, zero failures.
- Isolated `pnpm build`: release configuration, test bundle ID, ad-hoc signed.
- `extensions-smoke.mjs`: both phases passed, including installed extension
  persistence, content/worker/storage, disposable native messaging, real native
  popover, ungranted-host scripting rejection and clean shutdown.
- `smoke.mjs`: both phases passed (render/history/popup opener/storage/restart).
- `download-smoke.mjs`: bytes/progress/cancel/network failure/destination cancel passed.
- `pump-smoke.mjs`: two fixed10/adaptive pairs, zero reentries; fixed wakes
  409/413 versus adaptive 160/147. These are short app-process measurements.
- `browser-smoke.ts` with the built native daemon: three isolated runs passed,
  including scoping, snapshots/password exclusion, screenshots, actions, hidden
  tabs, popups, navigation, disconnect/crash cancellation and restart recovery.
- `extension-origin-smoke.mjs`: all 12 cases match Chrome and the SW POST
  Origin assertion passes. The fixture owns the fetch code in `probe.js`.

The x64 pin is updated but x64 runtime was not exercised on this arm64 Mac.
These are isolated ad-hoc builds, not Developer ID/notarization or installed
production acceptance. The toolbar setup entry's real 1Password workflow still
needs the user's production check: confirm the existing identical manifest is
accepted, reload the extension, then verify account-ready, popup/tab UI,
embedded save/update/fill, unlock/re-lock and restart persistence. Do not close
#134 merely because the local Origin regression passes.

## Investigation record (2026-10-29)

The following observations come from isolated verification candidates and the
implementation coordinator's reports. Some later checks used a user-approved
desktop connection. These are not a completed installed-release acceptance test.

- Official Chrome Web Store installation succeeded and the extension remained
  enabled after restart. The tested version was 8.12.42.36 (MV3), stable ID
  `aeblfdkhhhdcdjpifhhbdiojplfjncoa`.
- The earlier setup view verified the official desktop helper and registered its
  standard native messaging host in the test profile. This preceded the later removal and restoration of the setup entry.
- Developer ID/static verification and main/helper dynamic validity checks using
  raw and Foundation-serialized plist data returned status 0 after Info.plist
  normalization. See [signing scope](macos-signing.md). Signing success does not
  prove vault access or extension usability.
- Desktop integration showed Connected, but usable accounts remained at zero and
  account-ready was not reached. Connected is not account-sync success.
- The Chrome-style toolbar popup stalled at its logo. Opening the extension page
  in a normal Chrome-style tab showed the same symptom.
- A Network list showed HTTP 500 for a remote official overview API request.
  Authentication headers, response bodies and vault items were not inspected or
  replayed. Overall service status was Operational at the time, and the user
  reported that their usual browser worked. Neither observation identifies the
  cause of the candidate's failing request.
- Embedded Alloy content-script injection and a menu affordance were observed.
  Actual saving, updating, filling and unlocking were not demonstrated.
- The original dummy form's CSP could prevent the inline extension iframe. That
  fixture was corrected; the earlier missing save UI is not evidence that Alloy
  is unsupported. Acceptance still did not complete after the correction.
- A separate MV3 sample exercised content scripts, worker/storage persistence and
  a disposable native host. Its success establishes those fixture paths, not
  1Password compatibility.

At that time the cause was undetermined; the later account-free investigation
above identifies the CEF Origin defect. No general
Alloy incompatibility has been established. Local diagnostic extracts and images
have not been published as attachments and are not publicly viewable evidence.
Issue #134 contains the non-sensitive findings and the follow-up plan.

## Conditions for resuming acceptance

Use an isolated candidate and disposable test data, with user-controlled trust
and desktop unlock. Follow the official [additional-browser procedure](https://support.1password.com/additional-browsers/):
1Password for Mac → Settings → Browser → Add Browser. That flow can add desktop
accounts to the extension automatically; a separate website login is not a
prerequisite. Native messaging and signature checks must remain intact; see
[connection security](https://support.1password.com/1password-browser-security/).

Confirm account-ready and usable extension UI before testing the following in
an **embedded neuraOS tab**, recording Chrome-style results separately:

- Save a new disposable login and update an existing one.
- Fill the login through the extension.
- Unlock and re-lock through the desktop integration.
- Restart neuraOS and repeat the save/fill/unlock checks.
- Recheck general extensions, browser MCP, downloads and normal browsing.

The Chrome-style extension window is outside browser MCP. Embedded tabs remain
automatable, so disconnect MCP for any tab containing vault-filled information.
Do not include account/tenant names, authentication headers or bodies, secrets,
vault items or full profiles in a public report. Keep real-account acceptance open until these checks succeed.
