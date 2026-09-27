# FN-08 application icon / build 9

2026-09-27, user request: “好的，给这个应用添加一个应用图标”. This authorizes the icon addition; it is not FN-08, M2 or project acceptance. Work remains uncommitted on `codex/fn-08-local-trial`, base `c57139c98e6b11bb41aa7c3a35e3ccd57bd6b01f`.

The icon is generated with the built-in image tool, then resized into the standard 10 macOS AppIcon slots. Source and exact prompts: `design/app-icon/README.md`. Both app configurations include the catalog. No Swift product source changes, new permissions or storage changes.

Build 9 uses the existing LocalTrial bundle identity, service and recovery directory. Install destination is a distinct `~/Applications/FinderNotes v0.1 Local Trial Build 9.app`; build 8 is retained. Both identities share the same recovery location; they must not be run concurrently. No old recovery file is migrated or deleted.

## Evidence boundaries

Prior build 8 tests and Finder/UI evidence remain in the parent directory. They are historical functional evidence; no full functional suite rerun is claimed for this asset-only addition. New checks focus on the catalog sizes, build, package metadata/signature, installed icon and GUI launch. All previous unresolved and unverified FN-08 items remain unchanged, including real Chinese composition, audible sound, collapse during playback, scrolling, two tooltip states, intermittent Finder top Services menu, TCC and nonlocal transfer behavior.

Before changes, the historical build 8 application ZIP listed in its manifest was already absent from its delivery directory. Its installed app, previous DerivedData app, source archive, manifest and prior evidence were present. The old manifests are preserved as history and are not rewritten to describe build 9. `preserved-before.json` fingerprints 79 existing files, including the installed and built build 8 application, tracked old evidence, the retained LocalTrial recovery record, and previously recorded user edits.

This report does not imply public release, notarization, or Dan acceptance.

## Executed checks and results

- `./scripts/prepare_app_icon.sh`: generated all ten named asset slots. `assets-check.json` verifies exact pixel sizes and no Swift product source diff against the base.
- `FINDERNOTES_BUILD_PROFILE=local-trial FINDERNOTES_DERIVED_DATA="$PWD/.build/DerivedData-build9" ./scripts/build_app.sh`: Release build succeeded. Log: `release-build.log`; identity 0.1.0 (9), existing LocalTrial service. Previous DerivedData was retained.
- `python3 -B scripts/install_local_trial.py`: installed to the new Build 9 path. Full copied-file digests: `install.json`. Repeating the same command returns failure before replacement: `install-collision.json`.
- `app-check.json`: compiled `AppIcon.icns` and `Assets.car` present; `CFBundleIconName` and `CFBundleIconFile` set to AppIcon. `codesign --verify --deep --strict` passed. Signature remains local ad hoc, no notarization or security change. Same host as build 8: macOS 26.6.2 (25G83), Apple M2, internal APFS, Xcode 27.0.
- GUI: explicit installed path launched as PID 7149. About window displayed the actual new icon and 0.1.0 (9); `about.png` and `about-ax.txt`. Finder Get Info displayed the icon on that exact app; `finder-info.png` and `finder-info-ax.txt`. macOS adds its own light rounded-square surround in the large preview; small Finder icon uses the blue artwork.
- UI tooling notes: reading AX after normal Quit reports App quit; an initial Go To typing action produced a partial path and was corrected with the actual text field; a stale menu element ID was rejected after a full AX refresh, then re-read before retry. These are recorded as UI automation limitations, not product test passes.
- Preservation: `preserved-after.json` confirms all 79 registered files unchanged. `fixtures-after.json` confirms all 15 synthetic files retain expected media hashes, identity, modes, own notes, Finder native comments and unrelated attributes. No media edits were made in this icon pass. Retained recovery JSON was unchanged.
- Package and source archive hashes and verification are in `manifest.json` and the build 9 delivery directory. The new source archive excludes its own hash list/final manifest and final Notion readback to avoid self-reference. It includes all available project evidence and the icon master.

## FN08-I07 — same-identity copies and cold service routing (open)

After normal Quit and confirming there was no FinderNotes process, Finder right-click Services on the existing synthetic portrait started build 8 (PID 8127), not build 9. Targeted `lsregister -f -v` of the new installed app succeeded, but another cold service invocation still started build 8 (PID 8783). Evidence: `before-cold-launch.json`, `finder-service-ax.txt`, `service-selected-build8-process.json`, `service-selected-build8-ax.txt`, `register-new-app.log`, `service-after-registration.json`.

Minimum usable procedure verified: normally quit the old instance, explicitly open the Build 9 installed path, then invoke Finder service. This loaded the expected saved synthetic portrait note and preview in the only running FinderNotes process, PID 9060, at the Build 9 installed path. Evidence: `service-warm-build9.json`, `service-warm-build9-ax.txt`, `service-warm-build9.png`. No recovery draft was loaded, discarded or saved. Application remains open on that already-saved synthetic image for Dan.

This is a new build-selection limitation, not evidence that the historic top-menu loading failure was fixed. Full build 9 cold-start trial is not accepted. Old apps and registrations were not removed and no global service cache was reset. Minimal next decision, if direct cold service launch is needed: Dan can authorize handling the previous installed copy while preserving a recoverable copy, followed by a separate exact-path cold-start check. Current no-overwrite authorization does not permit that step.

## Dan review

Inspect the installed Build 9 app and its icon in Finder/About. For current use, explicitly start Build 9 before invoking the service. Decide whether to keep the icon and whether to authorize later handling of the old installed copy to resolve cold routing. FN-08 remains for review, with all former unverified boundaries and the new routing limitation visible; no Done or project acceptance is implied.
