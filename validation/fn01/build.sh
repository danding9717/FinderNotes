#!/bin/zsh
set -euo pipefail

developer_dir="${FINDERNOTES_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR="$developer_dir"
source_file="${0:A:h}/FN01.swift"
output_file="${1:-${TMPDIR:-/tmp}/findernotes-fn01-probe}"
xcrun swiftc -sdk "$(xcrun --sdk macosx --show-sdk-path)" "$source_file" -o "$output_file"
print -r -- "$output_file"
