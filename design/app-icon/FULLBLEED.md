# Full-bleed icon correction (build 10)

User asked: “这个图标像访达一样，铺满”. The screenshot showed the build 9 blue icon inset into a gray-white system plate. The correction uses an opaque blue square with no pre-drawn rounded mask or transparent outer padding. The paper, folder and pencil design is retained. Built-in image_gen edit mode was used; no CLI fallback. Final source: `FinderNotes-fullbleed.png`. The previous `FinderNotes-master.png` and original prompts are retained as build 9 history.

`scripts/prepare_app_icon.sh` now downsamples the full-bleed source into the ten existing macOS asset slots. macOS applies its own icon shape. No product Swift, storage or permission changes.

## Final prompt

Edit the supplied FinderNotes icon for production use as an edge-to-edge macOS app icon. The attached original is the exact design to preserve: cyan-blue file folder, warm-white note sheet with three dark blue lines, yellow diagonal pencil with pink eraser, and rich blue satin gradient. Fix only the canvas coverage and composition. Output a completely OPAQUE SQUARE image: the rich blue gradient MUST cover the entire canvas edge to edge, including all four corners. No transparency, no padding, no margin, no gray or white outer plate, no rounded-square boundary drawn inside the image, no outside shadow. macOS itself will apply its final rounded mask. Enlarge the existing folder/paper/pencil group naturally to occupy about 85% of the canvas, keep its full silhouette safely inside the canvas with at least 7% internal safe space for the system mask. Keep the same colors, design language and relative positions. Preserve the paper lines and pencil details. Flat front-on app artwork, no new letters, symbols or objects, no text, no mockup. The result must be one solid square blue canvas, NOT a small rounded icon sitting on another background.

## Guidance

Apple's current app icon guidance calls for full-bleed opaque backgrounds and system-applied masking: https://developer.apple.com/design/human-interface-guidelines/app-icons . The guidance is principally for Icon Composer; legacy asset-catalog behavior is confirmed here only by this machine's actual build and UI, not inferred for every macOS version.
