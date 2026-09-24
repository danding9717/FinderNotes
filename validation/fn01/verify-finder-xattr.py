#!/usr/bin/env python3
"""Verify completed manual Finder steps; only then edit synthetic copies to test isolation."""
import argparse
import json
from pathlib import Path
import runpy
import tempfile

helpers = runpy.run_path(str(Path(__file__).with_name("run-xattr.py")), run_name="fn01_helpers")
command, attrs, sha, emit = (helpers[x] for x in ("command", "attrs", "sha", "emit"))
KEY = helpers["KEY"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path, help="The matrix's finder-ready root; never a media library")
    parser.add_argument("--probe", type=Path,
                        default=Path(tempfile.gettempdir()) / "findernotes-fn01-xattr-probe")
    args = parser.parse_args()
    root = args.root.resolve(strict=True)
    assert root.parent == Path(tempfile.gettempdir()).resolve()
    assert root.name.startswith("findernotes-fn01-xattr-")
    assert (root / ".fn01-xattr-owned").read_bytes() == b"FinderNotes FN-01 xattr synthetic run v1\n"
    baseline = json.loads((root / "finder-baseline.json").read_text())
    assert baseline["root"] == str(root) and baseline["attribute"] == KEY
    probe = args.probe.resolve(strict=True)
    samples = {name: command([probe, "sample", name]).stdout for name in ("mixed", "cjk2000")}

    def verify(path, sample, expected):
        result = command([probe, "read", root, str(path.relative_to(root)), sample])
        assert json.loads(result.stdout)["ok"]
        assert sha(path.read_bytes()) == expected["media_sha256"]
        values = attrs(path)
        assert values[KEY] == samples[sample]
        for key, value in expected["attributes_hex"].items():
            if key != KEY:
                assert values.get(key) == bytes.fromhex(value), f"Existing attribute changed: {key}"
        s = path.stat()
        return [s.st_dev, s.st_ino]

    # Check both originals and copies before any write. Presence alone is not UI evidence.
    files = []
    for ext, name in (("png", "image"), ("mov", "video")):
        expected = baseline["finder"][ext]
        original = root / "moved" / f"renamed-{name}.{ext}"
        copied = root / "moved" / f"copy-{name}.{ext}"
        assert not (root / expected["path"]).exists()
        original_id = verify(original, "mixed", expected)
        copy_id = verify(copied, "mixed", expected)
        assert original_id == expected["identity"], "Rename/move did not retain original identity"
        assert copy_id != original_id, "Copy must have a distinct file identity"
        files.append((ext, original, copied, expected))
        emit("finder-final-state-verified", type=ext, root=str(root),
             original_identity=original_id, copy_identity=copy_id,
             note="Final readback only; pair this with the human/UI operation record.")
    for ext, original, copied, expected in files:
        command([probe, "write-verify", root, str(copied.relative_to(root)), "cjk2000"])
        verify(copied, "cjk2000", expected)
        verify(original, "mixed", expected)
        emit("finder-copy-edit-isolation-verified", type=ext, root=str(root))
    emit("finder-summary", verified_types=["png", "mov"], root=str(root),
         note="Copies now contain cjk2000; this is a one-shot check after manual Finder operations.")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        emit("failed", error_type=type(error).__name__, error=str(error))
        raise
