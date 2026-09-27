# FN-08 — FinderNotes display name, build 11

2026-09-27. Dan accepted the full-bleed icon appearance and requested the simple app name “FinderNotes”, with version details in About. This is not explicit acceptance of all FN-08/M2/project deliverables. All work remains uncommitted on `codex/fn-08-local-trial`, base `c57139c98e6b11bb41aa7c3a35e3ccd57bd6b01f`; no push, merge or public release.

## Change and installed result

- Release `CFBundleName` and `CFBundleDisplayName`: `FinderNotes`. Version metadata: 0.1.0 (11). Native About panel uses the simple name and displays the version below it; no extra About feature or invented copyright/release date.
- Installation: `/Users/danding/Applications/FinderNotes.app`, verified absent before installation and published with the existing exclusive installer. Original version-named builds 8/9/10 remain untouched.
- Finder service display label: `用 FinderNotes 编辑笔记`. This removes version/trial wording and distinguishes it from the historical standard service `FinderNotes 编辑笔记`. Bundle ID `com.findernotes.FinderNotes.LocalTrial`, port `FinderNotesLocalTrial`, callback, permissions, and recovery directory remain unchanged. No recovery migration/cleanup.
- Build/test metadata checks, installer and current instructions are synchronized. Existing full-bleed icon and all Swift product code are unchanged.

## Actual validation

- `FINDERNOTES_BUILD_PROFILE=local-trial FINDERNOTES_DERIVED_DATA="$PWD/.build/DerivedData-build11" ./scripts/build_app.sh`: Release build succeeded with identity/name/version/service assertions (`release-build.log`). Separate DerivedData retains old builds.
- `python3 -B scripts/install_local_trial.py`: installed (`install.json`), then refused an existing same-name destination (`install-collision.json`). `info.json` captures actual compiled metadata.
- `codesign --verify --deep --strict`: passed; `verification.json` preserves actual ad hoc signature facts. Environment remains macOS 26.6.2 (25G83), Apple M2, internal APFS, Xcode 27.0. Not notarized; Intel slice and other environments remain untested.
- Before launch there were no FinderNotes processes. Finder selected/opened exact `FinderNotes.app`; `finder-name-ax.txt` and `process.json` record the selection and sole process PID 25557 at that path.
- Main window and menu bar display **FinderNotes** without version/trial wording (`main-name-ax.txt`). About displays **FinderNotes**, full-bleed icon and **0.1.0 (11)** (`about.png`, `about-ax.txt`).
- Finder context menu on the existing synthetic portrait visibly lists **用 FinderNotes 编辑笔记** (`service-label-ax.txt`). The label check did not invoke the service or edit the file. No cold-route or save/recovery regression is claimed for this pass.
- `preserved-after.json`: 166 of 167 historical entries match, including original icon assets, installed/built copies, evidence and registered user changes. One historical synthetic recovery JSON is absent; see FN08-I08 below. No media writes, Orbit actions, permission changes or service-cache reset. `git diff --check` passed.

## FN08-I08 — historical synthetic recovery record absent; cause unconfirmed

The registered synthetic readonly draft `B34273B6-7568-4D81-B469-D171057CCCFD.json` is currently absent from the unchanged LocalTrial recovery directory. The expected SHA-256 was `141083b8054b3d516d3ba729f77ce1ae2a1d6df77a0594d26a6fea198ae858b6`. This pass's `preserved-before.json` inherited that hash from the build 10 historical baseline without freshly checking it before work; it must not be described as a complete start-of-turn snapshot.

The recovery directory's observed mtime is 2026-09-27 14:19:02 UTC, earlier than this pass's baseline file (14:34:02), install (14:35:43) and process capture (14:36:22). This is consistent with an earlier removal, but does not identify the actor, cause or prove a precise deletion time. No save, restore or discard was performed during the name check. Product Swift code is unchanged, and startup's recovery enumeration does not remove records. These facts cannot establish whether the earlier removal was expected user action or a defect.

The failed initial preservation assertion was retained as a finding, not changed to a pass. No old draft was recreated, migrated or cleaned up. Minimal next step for acceptance: Dan confirms whether the earlier synthetic recovery record was deliberately saved/discarded; if not, preserve the historical recovery/UI evidence and investigate separately before accepting recovery safety. Historical successful recovery tests remain historical, not proof this record still exists. This issue does not by itself establish data loss caused by build 11.

The full functional suite was not rerun for this metadata-only change. Build 8's 140-test result remains historical; previous IME/sound/preview/scrolling/tooltip/TCC/transfer limitations and FN08-I07 remain open. A newly visible service label does not establish which copy a future cold invocation will launch. Continue explicitly opening the desired installed app and avoid concurrent LocalTrial copies.

Current installation/uninstallation steps: `docs/LOCAL_TRIAL.md`. Final ZIP/source archive paths and digests: `manifest.json` and `.build/Delivery/FinderNotes-0.1.0-11/`. About remains open for Dan's inspection. FN-08 returns to Review; final acceptance still requires Dan's separate decision.
