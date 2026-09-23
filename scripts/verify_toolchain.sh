#!/bin/zsh
set -euo pipefail

developer_dir="${FINDERNOTES_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if [[ ! -x "$developer_dir/usr/bin/xcodebuild" ]]; then
  print -u2 "Full Xcode not found at: $developer_dir"
  print -u2 'Set FINDERNOTES_DEVELOPER_DIR to the Xcode.app Contents/Developer directory.'
  exit 2
fi

export DEVELOPER_DIR="$developer_dir"
xcodebuild -version
xcrun --sdk macosx --show-sdk-version
xcrun swift --version

scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/findernotes-toolchain.XXXXXX")"
trap 'rm -rf -- "$scratch_dir"' EXIT
cat > "$scratch_dir/Smoke.swift" <<'SWIFT'
import AppKit

print("FinderNotes macOS toolchain ready")
SWIFT
xcrun swiftc -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  "$scratch_dir/Smoke.swift" -o "$scratch_dir/smoke"
"$scratch_dir/smoke"
