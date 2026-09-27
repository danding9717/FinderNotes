# FinderNotes application icon

Current build 10 uses the full-bleed correction in [FULLBLEED.md](FULLBLEED.md) and `FinderNotes-fullbleed.png`. The original master and generation history below belong to build 9 and are preserved. `prepare_app_icon.sh` now uses the full-bleed source.

Created on 2026-09-27 for the user-authorized FN-08 icon addition using the built-in `image_gen` tool. No CLI fallback or API key was used. The final master is `FinderNotes-master.png`; it is a 1254 × 1254 PNG with alpha. The Xcode asset catalog contains macOS 1x/2x slots, 16–1024 px, mechanically resized with `/usr/bin/sips`. The original generated files remain untouched.

Design: blue folder, warm-white note sheet and yellow pencil; no text or imitation Finder face. This adds an app identity graphic, with no change to editing, xattr storage, permissions or recovery.

## Initial generation prompt

Create one finished macOS application icon for FinderNotes, a quiet native utility for writing a note attached to an image or video file. Square 1024 by 1024 pixel canvas, transparent background outside the icon, no presentation mockup. Center a beautifully balanced large rounded-square tile with generous macOS-style outer margin, tile occupying about 82 percent of canvas width. Restrained vivid cornflower-to-deep-blue satin gradient tile, a softly sculpted cyan-blue file folder with a distinct top-left folder tab, and a single warm-white note sheet rising out of that folder. On the sheet just three bold short dark-blue horizontal strokes as abstract note lines, no letters or words. A small but bold golden-yellow pencil rests diagonally at the lower right across the folder, tip pointing lower-left, clean geometric silhouette. Flat front-facing view with subtle dimensional bevel and soft close ambient shadows, crisp impeccably clean edges, premium macOS utility aesthetic. Strong simple silhouettes that remain legible at 16 and 32 pixels, restrained detail, spacious composition. The white paper is the focal point; folder and pencil communicate file notes. No Finder face, no Apple logo, no brand copying, no text, no watermark, no extra objects, no drop shadow beyond the icon's immediate edge. Single final icon only.

## Final refinement prompt

Refine this same FinderNotes application icon. Preserve its blue rounded-square tile, cyan folder, warm-white sheet with three navy note strokes, and yellow pencil. Clean the outer alpha silhouette thoroughly: remove every blue/cyan speckle, fringe, particle and stray pixel outside the smooth rounded-square tile. Reduce icon tile to exactly about 82% of the square canvas width and height, with an even transparent margin on all four sides. The outline must be a pristine smooth anti-aliased rounded rectangle with continuous curvature, no roughness, no outer shadow, no glow. Keep the interior polished and as close to the original as possible. A single final app icon on genuinely transparent background; no backdrop, grid, text, labels, or mockup. Target a square image.

## Reproduce packaged sizes

Run `./scripts/prepare_app_icon.sh` from this checkout. This only downsamples the saved master and writes the explicitly named AppIcon assets; it does not invoke an image service. Xcode compiles the catalog into `Assets.car` and `AppIcon.icns` through its normal Resources phase.
