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
  fn05)
    if [[ "$configuration" == Release ]]; then
      profile_settings=(FINDERNOTES_APP_SUFFIX=.FN05Validation FINDERNOTES_INFO_SUFFIX=-FN05Validation FINDERNOTES_TEST_SUFFIX=.FN05Tests)
    else
      profile_settings=(FINDERNOTES_APP_SUFFIX=.FN05Tests FINDERNOTES_INFO_SUFFIX=-FN05Tests FINDERNOTES_TEST_SUFFIX=.FN05Tests)
    fi
    ;;
  fn06)
    if [[ "$configuration" == Release ]]; then
      profile_settings=(FINDERNOTES_APP_SUFFIX=.FN06Validation FINDERNOTES_INFO_SUFFIX=-FN06Validation FINDERNOTES_TEST_SUFFIX=.FN06Tests)
    else
      profile_settings=(FINDERNOTES_APP_SUFFIX=.FN06Tests FINDERNOTES_INFO_SUFFIX=-FN06Tests FINDERNOTES_TEST_SUFFIX=.FN06Tests)
    fi
    ;;
  fn07)
    if [[ "$configuration" == Release ]]; then
      profile_settings=(FINDERNOTES_APP_SUFFIX=.FN07Validation FINDERNOTES_INFO_SUFFIX=-FN07Validation FINDERNOTES_TEST_SUFFIX=.FN07Tests)
    else
      profile_settings=(FINDERNOTES_APP_SUFFIX=.FN07Tests FINDERNOTES_INFO_SUFFIX=-FN07Tests FINDERNOTES_TEST_SUFFIX=.FN07Tests)
    fi
    ;;
  local-trial)
    if [[ "$configuration" == Release ]]; then
      profile_settings=(FINDERNOTES_APP_SUFFIX=.LocalTrial FINDERNOTES_INFO_SUFFIX=-LocalTrial FINDERNOTES_TEST_SUFFIX=.FN08Tests)
    else
      profile_settings=(FINDERNOTES_APP_SUFFIX=.FN08Tests FINDERNOTES_INFO_SUFFIX=-FN08Tests FINDERNOTES_TEST_SUFFIX=.FN08Tests)
    fi
    ;;
  m1fix)
    if [[ "$configuration" == Release ]]; then
      profile_settings=(FINDERNOTES_APP_SUFFIX=.M1FixValidation FINDERNOTES_INFO_SUFFIX=-M1FixValidation FINDERNOTES_TEST_SUFFIX=.M1FixTests)
    else
      profile_settings=(FINDERNOTES_APP_SUFFIX=.M1FixTests FINDERNOTES_INFO_SUFFIX=-M1FixTests FINDERNOTES_TEST_SUFFIX=.M1FixTests)
    fi
    ;;
  *) print -u2 'FINDERNOTES_BUILD_PROFILE must be standard, fn05, fn06, fn07, local-trial, or m1fix.'; exit 2 ;;
esac
project_root="${0:A:h:h}"
derived_data="${FINDERNOTES_DERIVED_DATA:-$project_root/.build/DerivedData}"

xcodebuild -project "$project_root/FinderNotes.xcodeproj" \
  -scheme FinderNotes -configuration "$configuration" \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$derived_data" "${profile_settings[@]}" "$@" build

app_path="$derived_data/Build/Products/$configuration/FinderNotes.app"
codesign --verify --deep --strict "$app_path"
if [[ "$profile" == fn05 || "$profile" == fn06 || "$profile" == fn07 || "$profile" == m1fix ]]; then
  actual_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist")"
  if [[ "$configuration" == Debug ]]; then
    if [[ "$profile" == fn05 ]]; then
      expected_id=com.findernotes.FinderNotes.FN05Tests
    elif [[ "$profile" == fn06 ]]; then
      expected_id=com.findernotes.FinderNotes.FN06Tests
    elif [[ "$profile" == fn07 ]]; then
      expected_id=com.findernotes.FinderNotes.FN07Tests
    else
      expected_id=com.findernotes.FinderNotes.M1FixTests
    fi
  elif [[ "$profile" == fn05 ]]; then
    expected_id=com.findernotes.FinderNotes.FN05Validation
  elif [[ "$profile" == fn06 ]]; then
    expected_id=com.findernotes.FinderNotes.FN06Validation
  elif [[ "$profile" == fn07 ]]; then
    expected_id=com.findernotes.FinderNotes.FN07Validation
  else
    expected_id=com.findernotes.FinderNotes.M1FixValidation
  fi
  [[ "$actual_id" == "$expected_id" ]] || { print -u2 "Unexpected $profile app identity: $actual_id"; exit 2; }
fi
if [[ "$profile" == local-trial ]]; then
  /usr/bin/python3 - "$app_path/Contents/Info.plist" "$configuration" <<'PY'
import plistlib
import sys

with open(sys.argv[1], 'rb') as source:
    info = plistlib.load(source)
release = sys.argv[2] == 'Release'
expected = {
    'CFBundleIdentifier': 'com.findernotes.FinderNotes.' + ('LocalTrial' if release else 'FN08Tests'),
    'CFBundleName': 'FinderNotes' if release else 'FinderNotes FN08 Tests',
    'CFBundleShortVersionString': '0.1.0',
    'CFBundleVersion': '11',
}
if release:
    expected['CFBundleDisplayName'] = 'FinderNotes'
for key, value in expected.items():
    if info.get(key) != value:
        sys.exit(f'Unexpected local-trial {key}: {info.get(key)!r}; expected {value!r}')
if release:
    services = info.get('NSServices', [])
    if len(services) != 1:
        sys.exit('local-trial must register exactly one Finder service.')
    service = services[0]
    if (service.get('NSMenuItem') != {'default': '用 FinderNotes 编辑笔记'}
            or service.get('NSPortName') != 'FinderNotesLocalTrial'
            or service.get('NSMessage') != 'receiveFiles'):
        sys.exit('Unexpected local-trial Finder service identity.')
elif 'NSServices' in info:
    sys.exit('FN08Tests must not register Finder services.')
print('Verified local-trial identity: ' + expected['CFBundleIdentifier'] + ' 0.1.0 (11)')
PY
fi
print -r -- "$app_path"
