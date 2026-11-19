# Vendored SwiftTerm

- Upstream: https://github.com/migueldeicaza/SwiftTerm
- Base: tag `v1.20.0`, commit `5d14406844143538cd8f8851d2d8a67c1fe443e5`
- Licence: MIT (`LICENSE`, bundled into the app by `scripts/native/build.mjs`)

`Sources/SwiftTerm` is the upstream directory of that commit, minus
`Documentation.docc`, `iOS` and `Mac/README.md`. `Package.swift` keeps only the
library target. `SwiftTermBuildInfo.swift` replaces upstream's build-tool plugin
with the values it generated for the tagged checkout.

The first commit that added this directory contains no other source change, so
`git log -- apps/macos/Vendor/SwiftTerm/Sources` lists every local modification.

## Why it is vendored

Upstream v1.99.x has the renderer work we want, but its manifest needs Swift
tools 6.2 and CI builds with Xcode 16.4 (Swift 6.1). Until the toolchain moves,
the Metal renderer hot paths are fixed here.

## Local changes

All are in the macOS Metal render path; the emulator, parser, input, selection
and CoreGraphics renderer are upstream code.

- `MetalTerminalRenderer`: glyph, scaled-font and shaper caches are keyed by a
  per-font integer instead of the PostScript name string; glyphs without ink
  are remembered; color-space conversion of component colors is remembered;
  the shaper cache hashes UTF-16 units and evicts without shifting an array.
  These keep upstream's cache identities and do not change what is drawn.
- `MetalTerminalRenderer` row cache: keyed by `BufferLine` identity. A row
  whose line generation, BiDi paragraph revision, selection, link highlight
  and blink phase are unchanged is not rebuilt when the parser reports it in a
  dirty range, and is repositioned (not rebuilt) when the screen scrolls.
  Rows with images or DEC double-size lines, and any redraw request that did
  not come from the parser, are rebuilt as upstream does.
- `Terminal`: records whether a redraw request came from outside `parse`.
- `TerminalView`: merges an unconsumed Metal dirty range instead of replacing
  it, exposes `metalRenderStatistics`, `metalRowReuseEnabled` and
  `metalVerifiesRowReuse`, and bumps an epoch when attribute caches are reset.

- `TerminalView`: `metalFrameRequests` (`MetalFrameRequestLedger`) records
  which frame requests no presented frame has answered, by draw generation;
  `unansweredMetalDisplayRequest` and `requestMetalFrame()` let the host detect
  and recover a renderer that is asked to draw but no longer presents.
  `apps/macos/Tests/NeuraOSTests/TerminalFrameRequestTests.swift` covers the ledger.

`defaults write <bundle id> SwiftTermDisableMetalRowReuse -bool YES` turns the
row reuse off at launch; the caches stay.
`apps/macos/Tests/NeuraOSTests/TerminalRenderReuseTests.swift` rebuilds every
reused row and compares it with the cached one.
