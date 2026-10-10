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
sparkle_path="$app_path/Contents/Frameworks/Sparkle.framework"
if [[ ! -d "$sparkle_path" ]]; then
  print -u2 'Sparkle.framework was not embedded in FinderNotes.app.'
  exit 2
fi
codesign --verify --deep --strict "$sparkle_path"
/usr/bin/python3 - "$app_path/Contents/Info.plist" "$sparkle_path/Resources/Info.plist" "$profile" <<'PY'
import base64
import plistlib
import sys

with open(sys.argv[1], 'rb') as source:
    info = plistlib.load(source)
with open(sys.argv[2], 'rb') as source:
    sparkle = plistlib.load(source)
if sparkle.get('CFBundleShortVersionString') != '2.10.0':
    sys.exit('Expected embedded Sparkle 2.10.0')
for key in ('SUEnableAutomaticChecks', 'SUAutomaticallyUpdate', 'SUAllowsAutomaticUpdates', 'SUEnableSystemProfiling'):
    if info.get(key) is not False:
        sys.exit(f'Expected {key}=false for manual updates only')
if info.get('SUVerifyUpdateBeforeExtraction') is not True:
    sys.exit('Expected EdDSA verification before extraction')
try:
    if len(base64.b64decode(info.get('SUPublicEDKey', ''), validate=True)) != 32:
        raise ValueError('Expected a 32-byte EdDSA public key')
except (ValueError, TypeError) as error:
    sys.exit(f'Invalid SUPublicEDKey: {error}')
feed = 'https://raw.githubusercontent.com/danding9717/FinderNotes/updates/appcast.xml'
if (info.get('SUFeedURL') == feed
        and info.get('CFBundleIdentifier') != 'com.findernotes.FinderNotes.LocalTrial'):
    sys.exit('Only the LocalTrial application may connect to the production update feed')
if sys.argv[3] != 'local-trial':
    if info.get('CFBundleIdentifier') == 'com.findernotes.FinderNotes':
        if info.get('FinderNotesUpdatesEnabled') is not False or info.get('SUFeedURL'):
            sys.exit('Standard development builds must keep updates disabled and omit SUFeedURL')
    print('Verified embedded Sparkle 2.10.0 and manual-update settings')
    sys.exit(0)
expected = {
    'CFBundleIdentifier': 'com.findernotes.FinderNotes.LocalTrial',
    'CFBundleName': 'FinderNotes',
    'CFBundleDisplayName': 'FinderNotes',
    'CFBundleShortVersionString': '0.1.3',
    'CFBundleVersion': '14',
    'FinderNotesUpdatesEnabled': True,
    'SUFeedURL': feed,
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
print('Verified local-trial identity: ' + expected['CFBundleIdentifier'] + ' 0.1.3 (14), Sparkle 2.10.0')
PY
print -r -- "$app_path"
