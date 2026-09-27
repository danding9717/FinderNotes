#!/bin/zsh
set -euo pipefail

developer_dir="${FINDERNOTES_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if [[ ! -x "$developer_dir/usr/bin/xcodebuild" ]]; then
  print -u2 "Full Xcode not found at: $developer_dir"
  print -u2 'Set FINDERNOTES_DEVELOPER_DIR to the Xcode.app Contents/Developer directory.'
  exit 2
fi
export DEVELOPER_DIR="$developer_dir"
configuration="${FINDERNOTES_CONFIGURATION:-Release}"
if [[ "$configuration" != Release && "$configuration" != Debug ]]; then
  print -u2 'FINDERNOTES_CONFIGURATION must be Release or Debug.'
  exit 2
fi
profile="${FINDERNOTES_BUILD_PROFILE:-standard}"
profile_settings=()
case "$profile" in
  standard) ;;
  local-trial)
    if [[ "$configuration" != Release ]]; then
      print -u2 'The local-trial profile requires Release configuration.'
      exit 2
    fi
    profile_settings=(FINDERNOTES_APP_SUFFIX=.LocalTrial FINDERNOTES_INFO_SUFFIX=-LocalTrial)
    ;;
  *) print -u2 'FINDERNOTES_BUILD_PROFILE must be standard or local-trial.'; exit 2 ;;
esac
project_root="${0:A:h:h}"
derived_data="${FINDERNOTES_DERIVED_DATA:-$project_root/.build/DerivedData}"

xcodebuild -project "$project_root/FinderNotes.xcodeproj" \
  -scheme FinderNotes -configuration "$configuration" \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$derived_data" "${profile_settings[@]}" "$@" build

app_path="$derived_data/Build/Products/$configuration/FinderNotes.app"
codesign --verify --deep --strict "$app_path"
if [[ "$profile" == local-trial ]]; then
  /usr/bin/python3 - "$app_path/Contents/Info.plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], 'rb') as source:
    info = plistlib.load(source)
expected = {
    'CFBundleIdentifier': 'com.findernotes.FinderNotes.LocalTrial',
    'CFBundleName': 'FinderNotes',
    'CFBundleDisplayName': 'FinderNotes',
    'CFBundleShortVersionString': '0.1.0',
    'CFBundleVersion': '11',
}
for key, value in expected.items():
    if info.get(key) != value:
        sys.exit(f'Unexpected local-trial {key}: {info.get(key)!r}; expected {value!r}')
services = info.get('NSServices', [])
if len(services) != 1:
    sys.exit('local-trial must register exactly one Finder service.')
service = services[0]
if (service.get('NSMenuItem') != {'default': '用 FinderNotes 编辑笔记'}
        or service.get('NSPortName') != 'FinderNotesLocalTrial'
        or service.get('NSMessage') != 'receiveFiles'):
    sys.exit('Unexpected local-trial Finder service identity.')
print('Verified local-trial identity: ' + expected['CFBundleIdentifier'] + ' 0.1.0 (11)')
PY
fi
print -r -- "$app_path"
