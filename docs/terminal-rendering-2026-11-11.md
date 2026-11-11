# Terminal rendering cost — 2026-11-11

## What was measured before the change

A five-second `sample` of the installed app (build 79) with one Claude Code
terminal animating showed 773 of about 860 busy main-thread samples under
SwiftTerm's `MetalTerminalRenderer.draw(in:)`, almost all of it rebuilding rows
(`buildRowDrawData`). That is a diagnostic sample of one session, not a
benchmark. The installed app was not modified or relaunched for this work, so
no number below is a measurement of the installed app.

## Changes

SwiftTerm v1.20.0 is now vendored in `apps/macos/Vendor/SwiftTerm` with fixes
to its Metal renderer (`VENDORED.md` there lists them). In short:

- Rows are kept when their line did not change. Upstream rebuilds every row
  between the first and last row the parser touched, and every visible row
  whenever the screen scrolls. Now a row is rebuilt only when its
  `BufferLine` generation, BiDi paragraph, selection, link highlight or blink
  phase changed; a row that only moved is repositioned.
- Glyph, font, shaping and color lookups no longer copy and hash the font's
  PostScript name per glyph, re-measure ink-less glyphs (spaces) per cell, or
  convert the color space per text run.
- `NativeTerminal` no longer marks the (empty) terminal `NSView` dirty for
  every output batch when the Metal renderer is active.

Redraw requests that do not come from parsed output (showing a hidden
terminal, selection, option changes) rebuild the affected range as before.
`defaults write <bundle id> SwiftTermDisableMetalRowReuse -bool YES` disables
the row reuse at launch and leaves the lookup caches on.

Upstream v1.99.x contains a reworked renderer, but it was not adopted: its
manifest requires Swift tools 6.2 while CI builds with Xcode 16.4 (Swift 6.1),
and its API differs (for example `TerminalView.getTerminal()` and the `MTKView`
subview this app uses to pause hidden terminals are gone). It was not
benchmarked.

## Benchmark

`apps/macos/Benchmarks/TerminalRender` is a stand-alone release executable that
drives `TerminalView` with its Metal renderer through public API: a 158×50
terminal at 2× scale, 200 frames per workload, each frame fed and then drawn
once. It reports CPU time of the calling thread inside SwiftTerm's
`draw(in:)`, and main-thread and process CPU for the whole loop. With
`SWIFTTERM_PATH` it builds against another checkout; "upstream" below is an
unmodified v1.20.0 checkout running the same source file.

Workloads (all mix ASCII, SGR colors, CJK, emoji and box drawing):

- `spinner-diff`: only a spinner row and a status row are written; an input
  box drawn with box-drawing characters lies between them.
- `stream-scroll`: two new transcript lines scroll the screen per frame.
- `region-repaint`: the lower 25 rows are erased and rewritten each frame,
  mostly with identical text, inside synchronized output.
- `full-repaint`: all 50 rows receive new text each frame.

Apple M1, 8 cores, 16 GiB, macOS 26. Two other build-heavy jobs were running on
the machine (load average 5–7 during the runs). Four runs per variant in the
order upstream, patched, caches-only, then reversed, twice. Values are the
median and [min–max] of those four runs, in CPU milliseconds per frame.
"caches-only" is the patched build with `SwiftTermDisableMetalRowReuse` set.

| Workload | Metric | Upstream v1.20.0 | Caches only | Patched |
| --- | --- | ---: | ---: | ---: |
| spinner-diff | draw | 6.24 [4.69–6.82] | 3.54 [3.13–3.97] | 1.76 [1.64–1.79] |
| | main thread | 7.38 [5.68–8.06] | 4.68 [4.17–5.21] | 3.03 [2.87–3.09] |
| | process | 8.41 [6.59–9.19] | 5.76 [5.16–6.40] | 4.28 [4.05–4.36] |
| stream-scroll | draw | 14.38 [14.21–15.13] | 11.19 [9.58–11.97] | 2.66 [2.46–2.89] |
| | main thread | 15.05 [14.88–15.86] | 12.00 [10.39–12.85] | 4.16 [3.86–4.52] |
| | process | 15.57 [15.38–16.44] | 12.70 [11.08–13.62] | 5.30 [4.95–5.78] |
| region-repaint | draw | 14.50 [14.04–14.90] | 11.55 [10.29–13.17] | 7.36 [6.59–8.31] |
| | main thread | 15.43 [14.84–15.76] | 12.67 [11.36–14.39] | 8.94 [7.99–10.09] |
| | process | 16.02 [15.34–16.31] | 13.43 [12.09–15.18] | 9.99 [8.91–11.29] |
| full-repaint | draw | 14.69 [14.39–15.00] | 12.45 [9.59–12.95] | 10.26 [8.76–10.94] |
| | main thread | 15.75 [15.39–15.98] | 13.83 [10.81–14.36] | 11.80 [10.18–12.57] |
| | process | 16.30 [15.89–16.45] | 14.51 [11.49–15.04] | 12.56 [10.88–13.34] |

Rows rebuilt per frame (deterministic counters, patched build only):

| Workload | Reuse disabled | Patched |
| --- | ---: | ---: |
| spinner-diff | 7.8 | 2.0 |
| stream-scroll | 71.5 | 2.0 (48 repositioned) |
| region-repaint | 59.9 | 25.0 |
| full-repaint | 71.0 | 50.0 |

With reuse disabled the count exceeds the rows written because a draw that
lands between parsing and SwiftTerm's ~60 Hz display pass rebuilds the changed
rows, and the display pass then reports them dirty and they are rebuilt again.

## How far these numbers go

- The ranges of the patched and upstream columns do not overlap for any
  workload, so the direction is reliable. The size is not precise: with four
  runs on a loaded machine single runs lie up to about 25 % from their
  variant's median (`spinner-diff` upstream, `full-repaint` caches-only), and thread CPU time
  still depends on which core type ran the thread. Do not read the medians to
  more than about one significant figure of improvement.
- "main thread" and "process" include the benchmark's own run-loop waiting,
  roughly 1–1.5 ms per frame in every variant.
- The benchmark draws exactly once per fed frame. The app draws when AppKit
  schedules it, and may coalesce several output batches into one draw, so CPU
  per second in the app is not these values times a frame rate.
- `region-repaint` and `full-repaint` improve least. A line that is rewritten
  with identical bytes still gets a new generation and is rebuilt; comparing
  cell contents instead was not attempted. Which of the four patterns a given
  Claude Code or Codex version produces was not measured.
- GPU time, WindowServer compositing, energy and memory were not measured.
  The glyph, shaper and color caches are bounded; the row cache holds one
  entry per visible row, as upstream's did.

## Correctness checks

`TerminalRenderReuseTests` (run by `pnpm test:macos`) uses a test hook that
rebuilds every reused row and compares it with the cached data, cell by cell,
through: scrolling, selection changes with and without output, palette /
default-color / reverse-video changes, selection and foreground color
changes, scroll regions, insert/delete line, erase, a DEC double-width line,
scrollback viewing, the alternate screen, hide-then-show, resize and both
blink phases. It reports zero differences. Temporarily breaking the
color-epoch check, the reposition distance, or the blink and forced-redraw
checks together makes that test fail, so it does detect those faults. It
compares vertex data, not pixels, and it does not cover link hover (needs
pointer events), Kitty/Sixel images (such rows are never reused when dirty or
moved) or IME composition.

The remaining tests assert the row counts above for the spinner and scrolling
cases, upstream's counts when reuse is disabled, a full rebuild for a
view-requested refresh, and that Metal output does not invalidate the
terminal `NSView`. The tests that draw disable AppKit's automatic draws, so
each step is exactly one draw after SwiftTerm's display pass, and skip
themselves if the machine cannot provide a Metal drawable. On the pull
request's first CI run (macos-15 runner, Swift 6.1) they ran rather than
skipped.

Not verified: behaviour in the running app (the built app was not launched,
to avoid touching the installed service), and therefore paste, drag and drop,
link clicks, IME and resize ordering were checked only by the existing unit
tests, which pass unchanged; those code paths were not edited.
