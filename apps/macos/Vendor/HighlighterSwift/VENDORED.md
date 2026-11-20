# Vendored HighlighterSwift

- Upstream: https://github.com/smittytone/HighlighterSwift
- Base: tag `3.1.0`, commit `fe7aae9c9b31d3b296fd3d2dd575e1a207bb29e0`
- Licence: MIT (`LICENCE.md`, bundled into the app by `scripts/native/build.mjs`);
  Highlight.js is BSD 3-Clause (`Sources/Assets/LICENCE`)

`Sources/Highlighter` and `Sources/Assets/highlight.min.js` are the upstream
files of that commit. Of upstream's themes only the three the app loads are
kept: `default-light` (required by `Highlighter.init`), `atom-one-light` and
`atom-one-dark`. `Package.swift` keeps only the library target.

The first commit that added this directory contains no source change, so
`git log -- apps/macos/Vendor/HighlighterSwift/Sources` lists every local
modification.

## Why it is vendored

`Highlighter.init` reads its resources through SwiftPM's generated
`Bundle.module`. With the command-line build used for releases that accessor
looks only in the `.app` root and at the build machine's absolute `.build`
path, and calls `fatalError` when neither exists. A packaged app keeps resource
bundles in `Contents/Resources`, so every installed release aborted the moment
a highlighter was created (opening a Markdown or code file). Upstream offers no
way to pass a bundle in.

## Local changes

- `Highlighter.init`: locates `Highlighter_Highlighter.bundle` itself, including
  in `Contents/Resources`, and returns `nil` when it is missing instead of
  aborting the process.
