#!/usr/bin/env python3
"""FN-01 isolated macOS xattr matrix; creates synthetic media, never accepts a library path."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import platform
import shutil
import subprocess
import sys
import tempfile
import time

KEY = "com.findernotes.note.v1"
NATIVE = "com.apple.metadata:kMDItemFinderComment"
SENTINEL = "com.findernotes.validation.sentinel"


def emit(event, **fields):
    print(json.dumps({"event": event, **fields}, ensure_ascii=False, sort_keys=True), flush=True)


def command(argv, expected=0):
    start = time.monotonic()
    result = subprocess.run([str(x) for x in argv], capture_output=True, timeout=60)
    emit("command", argv=[str(x) for x in argv], exit=result.returncode,
         elapsed_ms=round((time.monotonic() - start) * 1000, 3),
         stdout=result.stdout.decode("utf-8", errors="backslashreplace"),
         stderr=result.stderr.decode("utf-8", errors="backslashreplace"))
    if expected == "failure":
        assert result.returncode != 0, "Unexpected success"
    else:
        assert result.returncode == expected, "Unexpected exit status"
    return result


def sha(data):
    return hashlib.sha256(data).hexdigest()


def attribute(path, name):
    result = command(["/usr/bin/xattr", "-px", name, path])
    return bytes.fromhex(result.stdout.decode("ascii"))


def attrs(path):
    names = command(["/usr/bin/xattr", path]).stdout.decode().splitlines()
    return {name: attribute(path, name) for name in names}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--probe", type=Path,
                        default=Path(tempfile.gettempdir()) / "findernotes-fn01-xattr-probe")
    args = parser.parse_args()
    probe = args.probe.resolve(strict=True)
    prepared = json.loads(command([probe, "prepare"]).stdout)
    root = Path(prepared["root"]).resolve(strict=True)
    assert root.parent == Path(tempfile.gettempdir()).resolve()
    assert root.name.startswith("findernotes-fn01-xattr-")
    emit("environment", root=str(root), probe=str(probe), platform=platform.platform(),
         machine=platform.machine(), python=sys.version, uid=os.getuid(),
         app_identity="command-line probe; not the future app (see codesign evidence)")
    command(["/usr/bin/codesign", "-dv", probe])
    command(["/usr/bin/sw_vers"])
    volume = command(["/bin/df", "-P", root]).stdout.decode().splitlines()[1].split()[0]
    command(["/usr/sbin/diskutil", "info", volume])
    samples = {}
    for name in ("mixed", "cjk2000", "utf8-16k", "empty"):
        samples[name] = command([probe, "sample", name]).stdout
        emit("sample", name=name, bytes=len(samples[name]), sha256=sha(samples[name]))
    assert len(samples["cjk2000"]) == 6000
    assert len(samples["utf8-16k"]) == 16384
    assert samples["empty"] == b""
    checks = []

    def passed(name, **details):
        checks.append(name)
        emit("passed", name=name, **details)

    def call(op, rel, *extra, failure=False):
        r = command([probe, op, root, rel, *extra], "failure" if failure else 0)
        data = json.loads(r.stderr if failure else r.stdout)
        assert data["ok"] is (not failure)
        return data

    def fixture(name, ext):
        path = root / "work" / f"{name}.{ext}"
        shutil.copyfile(root / f"seed.{ext}", path)
        for key, value in ((NATIVE, plistlib.dumps("FN-01 原生注释保留🙂", fmt=plistlib.FMT_BINARY)),
                           (SENTINEL, b"FN-01 other metadata\x00\xff")):
            command(["/usr/bin/xattr", "-wx", key, value.hex(), path])
        return path

    def relative(path):
        return str(path.relative_to(root))

    def identity(path):
        info = path.stat()
        return (info.st_dev, info.st_ino)

    def verify(path, sample, metadata, content_hash):
        call("read", relative(path), sample)  # Separate process from the writer.
        assert attribute(path, KEY) == samples[sample], "Independent xattr read mismatch"
        actual = attrs(path)
        for key, value in metadata.items():
            assert actual.get(key) == value, f"Existing metadata changed: {key}"
        assert sha(path.read_bytes()) == content_hash, "Media content changed"

    for ext in ("png", "mov"):
        for name in samples:
            path = fixture(f"text-{name}", ext)
            before = attrs(path)
            content_hash = sha(path.read_bytes())
            call("read", relative(path), "missing")
            write = call("write-verify", relative(path), name)
            assert write["other_xattrs_preserved"]
            verify(path, name, before, content_hash)
            passed(f"{ext}:text:{name}", bytes=len(samples[name]))
        path = root / "work" / f"text-empty.{ext}"
        call("clear-verify", relative(path))
        call("read", relative(path), "missing")
        assert KEY not in attrs(path)
        passed(f"{ext}:empty-versus-missing")

        # The CLI oracle writes first; the probe must read exactly those bytes.
        path = fixture("external", ext)
        command(["/usr/bin/xattr", "-wx", KEY, samples["mixed"].hex(), path])
        call("read", relative(path), "mixed")
        passed(f"{ext}:independent-writer-to-probe")

        path = fixture("cli-lifecycle", ext)
        before, content_hash, original_id = attrs(path), sha(path.read_bytes()), identity(path)
        call("write-verify", relative(path), "mixed")
        renamed = root / "work" / f"cli-renamed.{ext}"
        command(["/bin/mv", path, renamed])
        verify(renamed, "mixed", before, content_hash)
        assert identity(renamed) == original_id
        passed(f"{ext}:cli-rename", identity=original_id)
        moved = root / "moved" / renamed.name
        command(["/bin/mv", renamed, moved])
        verify(moved, "mixed", before, content_hash)
        assert identity(moved) == original_id
        passed(f"{ext}:cli-same-volume-move", identity=original_id)
        copied = root / "moved" / f"cli-copy.{ext}"
        command(["/bin/cp", "-p", moved, copied])
        verify(copied, "mixed", before, content_hash)
        assert identity(copied) != original_id
        passed(f"{ext}:cli-copy", original_identity=original_id, copy_identity=identity(copied))
        call("write-verify", relative(copied), "cjk2000")
        verify(copied, "cjk2000", before, content_hash)
        verify(moved, "mixed", before, content_hash)
        passed(f"{ext}:copy-edit-isolation")

        path = fixture("readonly", ext)
        call("write-verify", relative(path), "mixed")
        before = attrs(path)
        os.chmod(path, 0o444)
        try:
            error = call("write-verify", relative(path), "cjk2000", failure=True)
            assert error.get("errno") in (1, 13, 30), error
            assert attrs(path) == before
        finally:
            os.chmod(path, 0o644)
        passed(f"{ext}:readonly-error", error=error)

        path = fixture("no-read", ext)
        os.chmod(path, 0)
        try:
            error = call("read", relative(path), failure=True)
            assert error.get("errno") in (1, 13), error
        finally:
            os.chmod(path, 0o644)
        passed(f"{ext}:read-permission-error", error=error)

        path = fixture("disappeared", ext)
        path.unlink()  # Only the synthetic fixture just created above.
        error = call("write-verify", relative(path), "mixed", failure=True)
        assert error.get("errno") == 2, error
        passed(f"{ext}:disappeared-error", error=error)

        path = fixture("invalid-utf8", ext)
        command(["/usr/bin/xattr", "-wx", KEY, "fffe", path])
        call("read", relative(path), failure=True)
        assert attribute(path, KEY) == b"\xff\xfe"
        passed(f"{ext}:invalid-utf8-error")

        # Refuse links without writing either link's seed target.
        linked = root / "work" / f"symlink.{ext}"
        linked.symlink_to(root / f"seed.{ext}")
        call("write-verify", relative(linked), "mixed", failure=True)
        linked.unlink()
        linked = root / "work" / f"hardlink.{ext}"
        os.link(root / f"seed.{ext}", linked)
        try:
            call("write-verify", relative(linked), "mixed", failure=True)
        finally:
            linked.unlink()
        assert KEY not in attrs(root / f"seed.{ext}")
        call("write-verify", f"seed.{ext}", "mixed", failure=True)
        call("write-verify", f"../seed.{ext}", "mixed", failure=True)
        passed(f"{ext}:path-and-link-refusal")

    # Prepared only: these checks require actual Finder UI actions and a later readback.
    finder = {}
    for ext, name in (("png", "finder-image"), ("mov", "finder-video")):
        path = fixture(name, ext)
        call("write-verify", relative(path), "mixed")
        finder[ext] = {"path": relative(path), "identity": identity(path),
                       "media_sha256": sha(path.read_bytes()),
                       "attributes_hex": {k: v.hex() for k, v in attrs(path).items()}}
    manifest = {"root": str(root), "attribute": KEY, "finder": finder}
    (root / "finder-baseline.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    emit("finder-ready", **manifest)
    emit("summary", passed=len(checks), checks=checks, root=str(root),
         unverified=["Finder UI rename/move/copy pending", "cross-volume/network/iCloud/archive/transfer",
                     "system reboot", "signed/sandboxed app and service permissions",
                     "ENOTSUP/E2BIG/EROFS", "product editing/conflict/draft behavior"])


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        emit("failed", error_type=type(error).__name__, error=str(error))
        raise
