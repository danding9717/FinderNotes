#!/bin/zsh
set -euo pipefail
export DEVELOPER_DIR="${FINDERNOTES_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
source_dir="${0:A:h}"
run_root="${1:?Usage: build.sh NEW_RUN_ROOT}"
[[ -f "$run_root/run.json" ]] || exit 2
app="$run_root/FinderNotes FN02.app"
[[ ! -e "$app" ]] || { print -u2 'Build destination already exists; use a new run'; exit 2; }
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$source_dir/Info.plist" "$app/Contents/Info.plist"
cp "$run_root/run.json" "$app/Contents/Resources/run.json"
xcrun swiftc -sdk "$(xcrun --sdk macosx --show-sdk-path)" "$source_dir/Core.swift" "$source_dir/main.swift" -o "$app/Contents/MacOS/FinderNotesFN02"
codesign --force --sign - --identifier com.findernotes.validation.fn02 "$app"
codesign --verify --strict "$app"
print -r -- "$app"
