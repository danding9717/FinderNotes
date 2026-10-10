#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
developer_dir="${FINDERNOTES_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR="$developer_dir"
derived_data="${FINDERNOTES_DERIVED_DATA:-$project_root/.build/FN11}"
verification_dir="$project_root/.build/FN11Verification"
configuration="${FINDERNOTES_CONFIGURATION:-Debug}"
if [[ "$configuration" != Debug && "$configuration" != Release ]]; then
  print -u2 'FINDERNOTES_CONFIGURATION must be Debug or Release.'
  exit 2
fi
mkdir -p "$verification_dir"
run_lock="$verification_dir/.running"
if ! mkdir "$run_lock" 2>/dev/null; then
  print -u2 "FN-11 verification is already running, or a previous interrupted run left $run_lock."
  exit 2
fi
trap 'rmdir "$run_lock"' EXIT

if [[ "${FINDERNOTES_FN11_SKIP_BUILD:-0}" != 1 ]]; then
  FINDERNOTES_CONFIGURATION="$configuration" FINDERNOTES_DERIVED_DATA="$derived_data" \
    "$project_root/scripts/build_app.sh" > "$verification_dir/build.log" 2>&1 || {
      tail -n 80 "$verification_dir/build.log"
      exit 1
    }
fi

products="$derived_data/Build/Products/$configuration"
intermediates="$derived_data/Build/Intermediates.noindex"
architecture="$(uname -m)"
compiler_args=(-swift-version 6 -parse-as-library -g -sdk "$(xcrun --sdk macosx --show-sdk-path)"
               -target "$architecture-apple-macos26.0" -I "$products")
build_task_ui="${FINDERNOTES_FN11_BUILD_TASK_UI:-0}"
verification_executable="$verification_dir/fn11-verification"
compile_log="$verification_dir/compile.log"
if [[ "$build_task_ui" == 1 ]]; then
  compiler_args+=(-D FN11_TASK_REVIEW_UI)
  verification_executable="$verification_dir/fn11-task-ui"
  compile_log="$verification_dir/task-ui-compile.log"
fi
objects=()
for target in Markdown CAtomic cmark-gfm cmark-gfm-extensions; do
  target_objects=("$intermediates"/**/"$configuration"/"$target-t.build"/Objects-normal/"$architecture"/*.o(N)
                  "$intermediates"/**/"$configuration"/"$target.build"/Objects-normal/"$architecture"/*.o(N))
  if (( ${#target_objects} == 0 )); then
    print -u2 "No compiled objects for $target below $intermediates; run the $configuration build first."
    exit 2
  fi
  objects+=("${target_objects[@]}")
done

module_maps=("$products"/**/*.modulemap(N)
             "$derived_data/SourcePackages/checkouts/swift-cmark/src/include/module.modulemap"
             "$derived_data/SourcePackages/checkouts/swift-cmark/extensions/include/module.modulemap"
             "$derived_data/SourcePackages/checkouts/swift-markdown/Sources/CAtomic/include/module.modulemap")
for module_map in "${module_maps[@]}"; do
  case "$module_map" in
    *CAtomic*|*cmark*) compiler_args+=(-Xcc "-fmodule-map-file=$module_map") ;;
  esac
done
include_directories=("$products/include" "$derived_data/SourcePackages/checkouts/swift-markdown/Sources/CAtomic/include"
                     "$derived_data/SourcePackages/checkouts/swift-cmark/src/include"
                     "$derived_data/SourcePackages/checkouts/swift-cmark/extensions/include")
for include_directory in "${include_directories[@]}"; do
  compiler_args+=(-Xcc "-I$include_directory")
done

sources=("$project_root"/FinderNotes/*.swift)
sources=("${(@)sources:#*/main.swift}")
sources=("${(@)sources:#*/AppDelegate.swift}")
xcrun swiftc "${compiler_args[@]}" "${sources[@]}" "$project_root"/tests/FN11/*.swift \
  "${objects[@]}" -o "$verification_executable" \
  > "$compile_log" 2>&1 || {
    cat "$compile_log"
    exit 1
  }
if [[ "$build_task_ui" == 1 ]]; then
  print "FN-11 task UI built without launching: $verification_executable"
  exit 0
fi
"$verification_executable" "$verification_dir/layout.png" | tee "$verification_dir/result.log"
