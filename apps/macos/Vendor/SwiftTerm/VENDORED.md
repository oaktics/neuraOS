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
