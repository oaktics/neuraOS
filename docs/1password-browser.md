# 1Password in neuraOS: deferred acceptance

**1Password usability is deferred from this release at the user's request.**
Track the remaining work in [Issue #134](https://github.com/oaktics/neuraOS/issues/134).
This release covers native runtime performance work, general Chromium extension
support and signing infrastructure. It does not claim working 1Password account
sync, saving, filling or desktop unlocking. These deferred acceptance gates do
not block this release; general extension and signing regressions still do.

The dedicated 1Password setup entry is excluded from the release scope. Use
[browser extensions](browser-extensions.md) for general extension management;
this document preserves investigation results and future acceptance criteria,
not a supported 1Password setup workflow.

## Investigation record (2026-10-29)

The following observations come from isolated verification candidates and the
implementation coordinator's reports. Some later checks used a user-approved
desktop connection. These are not a completed installed-release acceptance test.

- Official Chrome Web Store installation succeeded and the extension remained
  enabled after restart. The tested version was 8.12.42.36 (MV3), stable ID
  `aeblfdkhhhdcdjpifhhbdiojplfjncoa`.
- The earlier setup view verified the official desktop helper and registered its
  standard native messaging host in the test profile. This historical check does
  not mean the dedicated setup UI is part of the current release.
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

The failure could involve account handoff, a particular remote request, CEF
behavior or extension compatibility; the cause remains undetermined. No general
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
vault items or full profiles in a public report. Reintroduce dedicated 1Password
setup guidance only after these acceptance checks succeed.
