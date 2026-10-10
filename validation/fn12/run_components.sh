#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h:h}"
validation_root="$project_root/.build/FN12Validation"
framework_root="$project_root/.build/FN12Dependencies/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
if [[ ! -d "$framework_root/Sparkle.framework" ]]; then
  print -u2 'Sparkle 2.10.0 framework is missing. Resolve the pinned project package first.'
  exit 2
fi
export DEVELOPER_DIR="${FINDERNOTES_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p "$validation_root/components"
sources=("$project_root"/FinderNotes/*.swift)
sources=("${(@)sources:#*/main.swift}")
xcrun swiftc -swift-version 6 -parse-as-library -whole-module-optimization -Xfrontend -disable-access-control \
  -module-name FN12ComponentChecks -target "$(uname -m)-apple-macos13.0" \
  -F "$framework_root" -framework Sparkle -framework AppKit -framework Quartz \
  -Xlinker -rpath -Xlinker "$framework_root" \
  "${sources[@]}" "$project_root/validation/fn12/ComponentChecks.swift" "$project_root/validation/fn12/AuditChecks.swift" \
  -o "$validation_root/components/FN12ComponentChecks"
"$validation_root/components/FN12ComponentChecks" | tee "$validation_root/components/results.log"
