# Swarmbell artwork

Forest Chime was selected by the owner on 18 November 2026. The original,
1254×1254 built-in ImageGen output is preserved unchanged as `ForestChime.png`.
The exact prompt is in `ForestChime-prompt.txt`.

`scripts/build-icons.swift` exports the selected artwork at 1024×1024 for iPhone
and Watch, which apply system masks, and an inset rounded tile for macOS.
`Swarmbell.png` and `Swarmbell.icns` are the macOS exports. The previous vector
mark in `Swarmbell.svg` is retained as legacy artwork, not the current icon source.

To regenerate all PNG exports and the macOS icon resource, run
`swift scripts/build-icons.swift` from the repository root. The script uses
CoreGraphics for platform sizing and masking, `sips` for iconset sizes, and
`iconutil` for the macOS resource.
