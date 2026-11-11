# macOS UI performance investigation — 2026-11-11

Scope: the Swift app outside the terminal renderer (state propagation, file and
Git panes, periodic refreshes, CEF glue). Work began at `eb8d0ce`. Measurements
were taken on an Apple M1 / 8 CPU / 16 GiB Mac while two other builds were
running, in debug test builds unless stated. Timings are indicative, not
controlled benchmarks; the work counts are deterministic.

## Git diff colouring

Selecting a change coloured the diff by calling `addAttribute` once per changed
line, outside an editing transaction. Each call ran its own `processEditing`
pass, which invalidates layout from that line to the end of the document, so
the cost was quadratic in the number of lines and entirely on the main thread.

The whole diff is now one editing transaction. For a 10,000-line diff with
7,000 coloured lines:

| | Editing passes | Main-thread time (3 runs) |
| --- | ---: | ---: |
| Before | 7,001 | 13.3–13.6 s |
| After | 1 | 14.0–14.7 ms |

An earlier run of the same comparison with a window-hosted text view gave 52 ms
→ 4 ms at 2,000 lines, 7.1 s → 35 ms at 10,000 and 36.9 s → 270 ms at 40,000;
its "after" figures re-coloured an already coloured buffer, so they flatter the
fix slightly and the table above is the cleaner comparison.
The pass count is asserted by `testDiffColoringIsOneEditingPassForTenThousandLines`,
together with the colour of the first and last lines (including non-ASCII
lines, whose offsets are UTF-16). Text layout of a large diff itself is
unchanged and still takes time proportional to its size.

## Editor text comparisons

`NSTextView.string` returns a bridged `NSString`. The editor stored that value
in the open document and compared the editor's contents with the binding on
every SwiftUI update, so each keystroke performed several comparisons that walk
UTF-16 up to the first difference: the tab's dirty marker, the explorer's dirty
set (twice), the draft-cache change check, the Save button and `updateNSView`.

The coordinator now converts the edited text to a native string once and
compares against that cached copy. If a change is not published (a
non-editable or hidden editor) the cache is cleared and the next update
compares the editor itself, as before.

A fixture replaying that comparison set for 20 keystrokes on text containing
Japanese comments (three runs each, including the insertion itself):

| Buffer | Edit position | Before | After |
| --- | --- | ---: | ---: |
| 20 KB | end | 112–118 ms | 18–21 ms |
| 100 KB | end | 573–582 ms | 85–113 ms |
| 20 KB | start | 26–28 ms | 21–32 ms |
| 100 KB | start | 122–126 ms | 87–141 ms |

The gain depends on where the edit is: comparisons stop at the first
difference, so edits near the start were already cheap and are unchanged within
noise. This fixture replays the comparisons, not the SwiftUI update itself.
`testEditorPublishesNativeTextAndComparesWithoutBridging` checks that published
text is native UTF-8 and that the cache cannot go stale.

## Refreshes while no window is on screen

The selected workspace refetched Git status every 3 s for as long as the app
ran, and the agent list on the home surface refetched every 3 s, whether or not
any neuraOS window was on screen. Each Git refresh makes the daemon run
`git status` and `git branch`; on this repository (325 tracked files) those two
processes cost about 30–35 ms of CPU together (three rounds of 20), i.e. about
1,200 refreshes, 2,400 process launches and roughly 40 s of CPU per hour.

Both loops now also require `AppVisibility.visible`, which follows AppKit's
application occlusion state and treats the frontmost app as visible. While the
app is hidden, minimized, on another Space or fully covered they issue no
requests; becoming visible restarts the loop with an immediate refresh. A
standalone AppKit check confirmed the notification and state for hide,
miniaturize and order-out; display sleep and screen lock were not exercised.
`AppVisibilityTests` posts 2,000 notifications and asserts that readers are
invalidated only by the two real transitions. GitHub and CI refreshes already
stop when the scene is inactive and are unchanged.

## Examined and left unchanged

- **State refresh per daemon event.** Every store write emits `state: true`,
  and the app answers with `GET /v1/state` (the whole snapshot, 33 KB for 10
  projects / 13 workspaces / 102 terminals here) plus `GET /v1/notifications`.
  The event history of the installed profile shows 762 such writes in the last
  24 hours, in 374 distinct seconds, at most 33 in one minute. At that rate the
  refetch is not a measurable cost. The 6,380-per-hour bursts on 2026-11-09 were
  the Codex reconciliation loop already fixed in `worktree-performance-2026-11-09.md`.
  Agent-table writes (35% of the last day's events) cannot change the snapshot
  but are indistinguishable from other writes in the stream message.
- **CEF pump with no browser open.** An isolated probe (Chromium initialized,
  no browser, small visible window, not frontmost) recorded 58–62 pump wakes
  per 10.9 s with the current 33 ms cap; macOS already throttles the timer of a
  background app. A 1 s cap with no browser reduced that to 11, but process CPU
  was indistinguishable (0.037–0.053 s versus 0.038–0.039 s). The change was
  not kept: no measurable CPU benefit for a change in CEF scheduling.
- **Chromium initialization at launch.** The same probe measured synchronous
  initialization at 0.49–0.68 s when warm (2.6–2.8 s on the first run of a new
  build), before the first window. Deferring it would shorten launch, but the
  lazy path through tab creation has never been used in production and was not
  verified here.
- **Request plumbing.** `DaemonClient.request`, including JSON decoding, runs
  off the main thread; it accounted for about 10 of 2,502 samples in a
  5-second sample with one animating terminal.

## Delivery boundary

These are source changes with local test evidence. No installed-app CPU,
energy or memory figure is claimed.
