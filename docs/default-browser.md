# Default web browser

neuraOS declares `http`/`https` URL handling (`CFBundleURLTypes`, written by
`scripts/native/build.mjs`), so macOS lists it under System Settings → Desktop &
Dock → Default web browser.

## Setting it

Settings (⌘,) → **ブラウザ** → 「neuraOSをデフォルトのブラウザにする」. This calls
`NSWorkspace.setDefaultApplication(at:toOpenURLsWithScheme:)` for `http` and
`https`; macOS asks the user to confirm. Revert from System Settings. Only a
packaged `.app` can be registered.

## Where links open

`AppDelegate.application(_:open:)` queues accepted links in `ExternalLinks`
(only `http`/`https` with a host and no embedded credentials).

- If a worktree is selected, a fixed tab covering it is put away and the worktree
  opens each link as a new ordinary browser tab (after its saved tabs are restored).
- If nothing takes the links within 2 s (8 s while the daemon is still
  connecting) — no worktree selected, deletion in progress, main window closed —
  they open in the Chrome-style extension window instead.

## Verification (2026-11-17)

Isolated build (`NEURA_APP_ID=com.neuraos.default-browser-test`, separate data
directory/port and daemon), temporarily copied to `~/Applications` and registered
with LaunchServices (apps under `/tmp` are not offered as handlers):

- Listed by `NSWorkspace.urlsForApplications(toOpen:)` for `http` and `https`.
- Cold launch with no workspace: link opened in the extension window.
- Cold launch with a selected scratch workspace: link opened as a workspace tab.
- Running app, two links at once: two additional tabs, last one focused.

The actual default-browser switch was not exercised, to avoid changing the
developer's system setting; confirm it once on the installed release.
