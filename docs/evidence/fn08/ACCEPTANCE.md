# FN-08 acceptance and closeout scope

On 2026-09-27 Dan explicitly stated: “验收通过，完成后续标准收尾工作，并合并分支”. This accepts the delivered FN-08 local trial and authorizes its standard commit, push, PR, Notion update, merge and safe synchronization. It does not authorize public distribution, a new task, or mark M2/the whole project accepted.

## Accepted object

- FinderNotes 0.1.0 (11), installed at `/Users/danding/Applications/FinderNotes.app`; bundle ID `com.findernotes.FinderNotes.LocalTrial`.
- Branch `codex/fn-08-local-trial`, based on `c57139c98e6b11bb41aa7c3a35e3ccd57bd6b01f`. The original delivery was uncommitted; the resulting Git SHA and merge result are recorded in Notion/PR after they actually exist.
- Scope: local-trial and test identities, build/test checks, exclusive installer, independent note read/export validation, full-bleed app icon, simple app/service naming, instructions and raw evidence. No Swift product implementation changes relative to the base.
- Delivery folder: `.build/Delivery/FinderNotes-0.1.0-11/`. Application ZIP SHA-256 `0c442b1780a26b018d148f2c8ff6c1444f271cf5090c5818d04797042194c9d0`; source/evidence archive SHA-256 `df387539630dc2a783f67d433426b3425cfe788fe4aa5fd976e4a309b1511428`.
- Closeout rechecked all 360 source/evidence hashes and both archives against the accepted manifest. All matched. These closeout documents are appended after that immutable delivery snapshot; they are not claimed to be inside its archive.

## Evidence boundaries retained

Build 8's full functional run remains 140 tests: 139 passed, one conditional skip, zero failures. Its file integration and Finder/UI evidence remain separately recorded. Builds 9/10/11 have their own resource, build, installation and limited UI checks; they do not inherit a claim that the full suite or all service/recovery flows were rerun. Acceptance is Dan's decision, not newly performed testing.

FN08-I07 remains open: earlier cold service routing selected a retained old app; build 11 only verified the new visible service label. FN08-I08 remains unresolved: a historical synthetic recovery JSON is absent, with an incomplete start-of-turn baseline and directory mtime predating the name change. Dan's acceptance does not identify how it was removed. No automatic recovery, migration or cleanup is authorized by this record.

Real Chinese composition, sound, stopping playback on collapse, long-text scrolling, hover tooltips, TCC, historical top-service behavior and untested transfers retain their documented limits. Support remains the observed macOS 26.6.2 (25G83), Apple M2, internal APFS, Xcode 27.0 environment; ad hoc/non-notarized distribution limits remain. Formal notes use only raw UTF-8 `com.findernotes.note.v1`, recovery protects successfully persisted drafts, and xattr check/write is not atomic CAS.

## Preservation and handoff

Historical reports and manifests retain their original Review/pending/uncommitted wording as time-specific evidence. Notion is the current task/acceptance record. No old apps, recovery files, synthetic fixtures, test results or delivery packages are automatic cleanup targets. The original checkout's modified `AGENTS.md` and untracked Xcode workspace must remain byte-for-byte intact.

No next implementation task was selected. See [post-FN-08 handoff](../../handoffs/AFTER-FN-08.md). Project-wide Done still requires Dan's separate explicit confirmation.
