#!/usr/bin/env python3
"""Read-only oracle for FN-04's separately generated synthetic UI fixtures."""
import argparse
import ctypes
import datetime
import errno
import hashlib
import json
import os
import pathlib
import stat
import sys

SCHEMA = "findernotes-fn04-fixtures-v1"
FILES = ("normal.png", "normal.mov", "empty.png", "missing.png", "invalid.png", "unreadable.png")
MARKER = ".fn04-owned.json"
LIBC = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
LIBC.fgetxattr.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_void_p,
                          ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
LIBC.fgetxattr.restype = ctypes.c_ssize_t
LIBC.flistxattr.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
LIBC.flistxattr.restype = ctypes.c_ssize_t


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def read_bytes(call):
    """A nonzero buffer avoids treating an empty-value read as another size query."""
    for _ in range(4):
        size = call(None, 0)
        if size < 0:
            code = ctypes.get_errno()
            raise OSError(code, os.strerror(code))
        buffer = ctypes.create_string_buffer(max(1, size))
        count = call(buffer, len(buffer))
        if 0 <= count <= len(buffer):
            return buffer.raw[:count]
        if count > len(buffer) or ctypes.get_errno() == errno.ERANGE:
            continue
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code))
    raise RuntimeError("Attribute changed repeatedly during verification")


def fingerprint(path):
    fd = os.open(str(path), os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        status = os.fstat(fd)
        if not stat.S_ISREG(status.st_mode) or status.st_nlink != 1:
            raise ValueError("Expected one regular, non-hard-linked synthetic file")
        digest = hashlib.sha256()
        while True:
            block = os.read(fd, 65536)
            if not block:
                break
            digest.update(block)
        names = read_bytes(lambda buffer, size: LIBC.flistxattr(fd, buffer, size, 0))
        attributes = {}
        for name in names.split(b"\0"):
            if name:
                value = read_bytes(lambda buffer, size: LIBC.fgetxattr(fd, name, buffer, size, 0, 0))
                attributes[name.decode("utf-8")] = value.hex()
        current = os.stat(path, follow_symlinks=False)
        if (current.st_dev, current.st_ino) != (status.st_dev, status.st_ino):
            raise ValueError("Fixture identity changed during verification")
        return {
            "mediaSHA256": digest.hexdigest(),
            "xattrHex": dict(sorted(attributes.items())),
            "device": status.st_dev,
            "inode": status.st_ino,
            "mode": format(stat.S_IMODE(status.st_mode), "04o"),
        }
    finally:
        os.close(fd)


def verify(raw_root):
    root = pathlib.Path(raw_root).resolve(strict=True)
    if not root.name.startswith("findernotes-fn04-"):
        raise ValueError("Not an FN-04 fixture root")
    marker = json.loads((root / MARKER).read_text())
    before = json.loads((root / "before.json").read_text())
    for document in (marker, before):
        if document["schema"] != SCHEMA or document["root"] != str(root):
            raise ValueError("Fixture marker/root mismatch")
    if marker["runID"] != before["runID"] or set(before["files"]) != set(FILES):
        raise ValueError("Fixture inventory mismatch")
    if (root / "work").is_symlink():
        raise ValueError("Fixture work directory must not be a symlink")
    checks = []
    for name in FILES:
        path = root / "work" / name
        expected = before["files"][name]
        check = {"file": name}
        try:
            current = os.stat(path, follow_symlinks=False)
            identity_matches = (current.st_dev, current.st_ino) == (expected["device"], expected["inode"])
            mode = format(stat.S_IMODE(current.st_mode), "04o")
            check.update(identityMatches=identity_matches, mode=mode, modeMatches=mode == expected["mode"])
            if not stat.S_ISREG(current.st_mode) or current.st_nlink != 1 or not identity_matches:
                raise ValueError("Fixture missing, replaced or changed into a link")
            if name == "unreadable.png" and mode == "0000":
                check.update(status="skipped-content", reason="mode 000; verifier does not change permissions",
                             mediaSHA256Matches=None, allXattrsMatch=None)
            else:
                after = fingerprint(path)
                check.update(status="compared", after=after,
                             mediaSHA256Matches=after["mediaSHA256"] == expected["mediaSHA256"],
                             allXattrsMatch=after["xattrHex"] == expected["xattrHex"])
        except (OSError, ValueError, RuntimeError) as error:
            check.update(status="error", error=str(error))
        checks.append(check)
    failures = [check["file"] for check in checks
                if check["status"] == "error" or not check.get("modeMatches", False)
                or check.get("mediaSHA256Matches") is False or check.get("allXattrsMatch") is False]
    skipped = [check["file"] for check in checks if check["status"] == "skipped-content"]
    return {
        "schema": SCHEMA, "root": str(root), "runID": marker["runID"], "verifiedAt": utc_now(),
        "status": "failed" if failures else "partial" if skipped else "passed",
        "comparedFilesMatch": not failures, "complete": not failures and not skipped,
        "failures": failures, "skippedContent": skipped,
        "fixtureMutationsByVerifier": [], "checks": checks,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", help="The exact new root printed by prepare.py")
    args = parser.parse_args()
    result = verify(args.root)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 1 if result["failures"] else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, RuntimeError) as error:
        print(json.dumps({"status": "failed", "error": str(error)}, ensure_ascii=False), file=sys.stderr)
        sys.exit(1)
