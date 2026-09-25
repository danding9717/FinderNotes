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
  *) print -u2 'FINDERNOTES_BUILD_PROFILE must be standard or fn05.'; exit 2 ;;
esac
project_root="${0:A:h:h}"
derived_data="$project_root/.build/DerivedData"

xcodebuild -project "$project_root/FinderNotes.xcodeproj" \
  -scheme FinderNotes -configuration "$configuration" \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$derived_data" "${profile_settings[@]}" "$@" build

app_path="$derived_data/Build/Products/$configuration/FinderNotes.app"
codesign --verify --deep --strict "$app_path"
if [[ "$profile" == fn05 ]]; then
  actual_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist")"
  if [[ "$configuration" == Release ]]; then
    expected_id=com.findernotes.FinderNotes.FN05Validation
  else
    expected_id=com.findernotes.FinderNotes.FN05Tests
  fi
  [[ "$actual_id" == "$expected_id" ]] || { print -u2 "Unexpected FN-05 app identity: $actual_id"; exit 2; }
fi
print -r -- "$app_path"
