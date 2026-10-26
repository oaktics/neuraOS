# App icon

`AppIcon.png` is the original artwork, generated with the built-in image_gen tool.
`AppIcon.icns` contains the macOS 16–1024 px representations, preserving transparency.

Regenerate the ICNS on macOS after replacing the artwork:

```sh
node scripts/native/build-icon.mjs
```

The native build copies the ICNS into the application bundle and registers it using
`CFBundleIconFile`. Both development and release builds use this icon.

## Generation prompt

Use case: logo-brand
Asset type: production macOS app icon for neuraOS, a native AI developer workspace.
Primary request: Create one exceptionally polished, cool, minimal app icon. A single sculptural folded ribbon forming a clear capital N, with broad bold strokes and precise beveled edges. Electric cyan transitioning through cobalt blue to subtle violet, on a deep midnight graphite rounded-square tile. Sophisticated native Mac app aesthetic, restrained luminous edges, elegant soft studio lighting, tactile satin glass/metal material, strong readable silhouette at small sizes.
Composition: square 1024x1024 canvas, centered rounded-square tile occupying 84% of canvas width and height, generous transparent outer margin, N occupies 60% of tile, straight-on view, restrained shadow, crisp clean boundaries.
Constraints: genuine transparent background outside tile; tile itself opaque dark graphite. Only one icon, no presentation sheet, no device mockup, no extra text, no wordmark, no tiny circuitry, no stars, no brain illustration, no border decoration, no watermark.
