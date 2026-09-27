#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
source_png="$project_root/design/app-icon/FinderNotes-fullbleed.png"
asset_root="$project_root/FinderNotes/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$asset_root"
for size in 16 32 128 256 512; do
  /usr/bin/sips -z "$size" "$size" "$source_png" --out "$asset_root/icon_${size}x${size}.png" >/dev/null
  doubled=$((size * 2))
  /usr/bin/sips -z "$doubled" "$doubled" "$source_png" --out "$asset_root/icon_${size}x${size}@2x.png" >/dev/null
done
print 'Prepared macOS AppIcon sizes from saved master.'
