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
  fn06) profile_settings=(FINDERNOTES_APP_SUFFIX=.FN06Tests FINDERNOTES_INFO_SUFFIX=-FN06Tests FINDERNOTES_TEST_SUFFIX=.FN06Tests) ;;
  fn07) profile_settings=(FINDERNOTES_APP_SUFFIX=.FN07Tests FINDERNOTES_INFO_SUFFIX=-FN07Tests FINDERNOTES_TEST_SUFFIX=.FN07Tests) ;;
  local-trial) profile_settings=(FINDERNOTES_APP_SUFFIX=.FN08Tests FINDERNOTES_INFO_SUFFIX=-FN08Tests FINDERNOTES_TEST_SUFFIX=.FN08Tests) ;;
  m1fix) profile_settings=(FINDERNOTES_APP_SUFFIX=.M1FixTests FINDERNOTES_INFO_SUFFIX=-M1FixTests FINDERNOTES_TEST_SUFFIX=.M1FixTests) ;;
  *) print -u2 'FINDERNOTES_BUILD_PROFILE must be standard, fn05, fn06, fn07, local-trial, or m1fix.'; exit 2 ;;
esac
project_root="${0:A:h:h}"
derived_data="${FINDERNOTES_DERIVED_DATA:-$project_root/.build/DerivedData}"
result_path="$project_root/.build/TestResults/FinderNotes-$(date +%Y%m%d-%H%M%S)-$$.xcresult"
mkdir -p "${result_path:h}"

xcodebuild -project "$project_root/FinderNotes.xcodeproj" \
  -scheme FinderNotes -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$derived_data" -resultBundlePath "$result_path" \
  -parallel-testing-enabled NO "${profile_settings[@]}" "$@" test

if [[ "$profile" == local-trial ]]; then
  /usr/bin/python3 - "$derived_data/Build/Products/Debug/FinderNotes.app/Contents/Info.plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], 'rb') as source:
    info = plistlib.load(source)
expected = {
    'CFBundleIdentifier': 'com.findernotes.FinderNotes.FN08Tests',
    'CFBundleName': 'FinderNotes FN08 Tests',
    'CFBundleShortVersionString': '0.1.0',
    'CFBundleVersion': '11',
}
for key, value in expected.items():
    if info.get(key) != value:
        sys.exit(f'Unexpected FN08Tests {key}: {info.get(key)!r}; expected {value!r}')
if 'NSServices' in info:
    sys.exit('FN08Tests must not register Finder services.')
print('Verified test identity: com.findernotes.FinderNotes.FN08Tests 0.1.0 (11), no Finder services')
PY
fi
print -r -- "$result_path"
