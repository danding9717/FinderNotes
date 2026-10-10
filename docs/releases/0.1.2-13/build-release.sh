#!/bin/zsh
set -euo pipefail
release_root="${0:A:h}"
export FINDERNOTES_DERIVED_DATA="$release_root/DerivedData"
export FINDERNOTES_BUILD_PROFILE=standard
"$release_root/source/scripts/build_app.sh" \
  FINDERNOTES_APP_SUFFIX=.LocalTrial \
  INFOPLIST_FILE="$release_root/Info-Release.plist" \
  -onlyUsePackageVersionsFromResolvedFile
