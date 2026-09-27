# Final process-evidence clarification

The first shell observation immediately after Finder service invocation listed only old installed build 8, PID 8127. After requesting its UI through `cua.getApp` using the old installed path, the later saved `service-selected-build8-process.json` listed **both** old PID 8127 and new build 9 PID 8500. The exact origin/timing of PID 8500 is not established. Do not treat that saved snapshot as proof that only build 8 was running, or claim that the entire check never had two copies at once. This was an observed overlap, not an intended concurrent-use test; no text editing, save, recovery restore or discard was performed during it.

The next cold-service snapshot, `service-after-registration.json`, lists only old PID 8783. After normal Quit, a shell check confirmed no FinderNotes instance before explicitly launching build 9. The final `service-warm-build9.json` lists only new PID 9060, with the expected synthetic note and preview. Thus direct cold routing remains unresolved; the explicit-start-9-then-service procedure has bounded positive evidence.

The 79 registered preserved files and the 15 synthetic fixture checks passed after these UI actions, including the retained recovery JSON. This does not establish general concurrent-instance safety. Do not deliberately run both copies together. Prior unsupported/unverified boundaries remain.

This clarification was added after the build 9 source archive was sealed. It is delivered alongside that archive and referenced by both final manifests; it is not inside the 323-file source archive. Archive hashes and the original observations remain unchanged.
