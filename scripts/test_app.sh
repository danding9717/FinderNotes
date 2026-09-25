#!/bin/zsh
set -euo pipefail

developer_dir="${FINDERNOTES_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if [[ ! -x "$developer_dir/usr/bin/xcodebuild" ]]; then
  print -u2 "Full Xcode not found at: $developer_dir"
  print -u2 'Set FINDERNOTES_DEVELOPER_DIR to the Xcode.app Contents/Developer directory.'
  exit 2
fi
export DEVELOPER_DIR="$developer_dir"
profile="${FINDERNOTES_BUILD_PROFILE:-standard}"
profile_settings=()
case "$profile" in
  standard) ;;
  fn05) profile_settings=(FINDERNOTES_APP_SUFFIX=.FN05Tests FINDERNOTES_INFO_SUFFIX=-FN05Tests FINDERNOTES_TEST_SUFFIX=.FN05Tests) ;;
  *) print -u2 'FINDERNOTES_BUILD_PROFILE must be standard or fn05.'; exit 2 ;;
esac
project_root="${0:A:h:h}"
derived_data="$project_root/.build/DerivedData"
result_path="$project_root/.build/TestResults/FinderNotes-$(date +%Y%m%d-%H%M%S)-$$.xcresult"
mkdir -p "${result_path:h}"

xcodebuild -project "$project_root/FinderNotes.xcodeproj" \
  -scheme FinderNotes -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$derived_data" -resultBundlePath "$result_path" \
  -parallel-testing-enabled NO "${profile_settings[@]}" "$@" test

print -r -- "$result_path"
