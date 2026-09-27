# FN-08 — full-bleed icon, build 10

2026-09-27: Dan asked “这个图标像访达一样，铺满” and provided a screenshot of build 9's small blue icon inside a gray-white system plate. This is an appearance correction within FN-08, not task or project acceptance. Branch `codex/fn-08-local-trial`, base `c57139c98e6b11bb41aa7c3a35e3ccd57bd6b01f`; all changes remain uncommitted, no push, merge or public release.

## Change

Built-in image_gen edited the existing folder/paper/pencil design into an opaque, edge-to-edge blue square. No transparent outer margin, inset rounded tile or pre-drawn outer shadow. The system applies the final rounded mask. Final source and full prompt: `design/app-icon/FULLBLEED.md`, `FinderNotes-fullbleed.png`. Original build 9 master and sealed artifacts are retained.

`prepare_app_icon.sh` uses the new master; the existing ten macOS AppIcon slots and Xcode catalog integration remain. LocalTrial/FN08Tests build numbers, installer and current documentation advance to 10. No Swift product source, storage, service identity or permission changes. Stable LocalTrial recovery directory remains shared; no old draft is read into an editor, migrated, saved or discarded in this pass.

## Executed validation

- `./scripts/prepare_app_icon.sh` generated all ten exact-sized PNGs. `assets-check.json` confirms correct dimensions, no alpha, and compiled app Info with build 10 and AppIcon declaration.
- `FINDERNOTES_BUILD_PROFILE=local-trial FINDERNOTES_DERIVED_DATA="$PWD/.build/DerivedData-build10" ./scripts/build_app.sh` succeeded; `release-build.log` retained. Separate DerivedData preserved all prior builds.
- `python3 -B scripts/install_local_trial.py` installed to `/Users/danding/Applications/FinderNotes v0.1 Local Trial Build 10.app`; `install.json` records copied-file digests. Repeated installation refused replacement (`install-collision.json`).
- Strict codesign verification passed (`verification.json`); local ad hoc, not notarized. Same actual host: macOS 26.6.2 (25G83), Apple M2, internal APFS, Xcode 27.0. Intel slice is built but remains untested.
- Finder Get Info on the exact installed build 10 visibly shows the blue icon filling the rounded icon area, with no gray-white surrounding plate: `finder-info.png` and full `finder-info-ax.txt`.
- Previous build 9 was confirmed showing the already-loaded synthetic portrait without new edits, then normally quit. Shell confirmed no FinderNotes process. Finder selected the exact new installed app and opened it. `process.json` records the sole process PID 17173 at the Build 10 path.
- CUA selection by bundle ID was rejected as ambiguous because retained copies share that identity; binding by exact already-running path succeeded. About window visibly shows the full blue icon and version 0.1.0 (10): `about.png` and `about-ax.txt`. Final shell observation still records only build 10. App remains open at About for Dan's visual review.
- `preserved-after.json`: all 123 registered old files match their prior SHA-256, including old apps, build 9 archives/evidence, original icon, registered user edits and retained recovery JSON. This pass did not send any media to the new app or edit notes. No Orbit/real-media operations.
- `git diff --check` passed. No full functional tests rerun for this resource-only correction; build 8's 140-test result remains historical. No new claim about IME, sound, playback collapse, scrolling, tooltips, TCC, transfers or recovery concurrency.

## Remaining limits and review

FN08-I07 remains open: previous build 9 testing showed cold Finder service selecting retained build 8; this icon-only pass did not retest or fix service routing. Explicitly launch the desired installed build before using Finder service, avoid concurrent copies, and confirm the actual path. The build 9 warm-route evidence is not claimed as a new build 10 test. Historical top-menu loading behavior and all prior unverified boundaries remain unchanged.

Dan can inspect the actual Finder/About icon and choose whether the full-bleed appearance meets the request. FN-08 returns to Review only, not Done; M2/project acceptance remains separate. Current installation/uninstallation instructions: `docs/LOCAL_TRIAL.md`. Final app/source package hashes, paths and archive verification are in this directory's `manifest.json` and `.build/Delivery/FinderNotes-0.1.0-10/`.
