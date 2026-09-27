#!/usr/bin/env python3
"""Read-only comparison of FN-06 synthetic media, note and unrelated xattrs."""

import argparse
import ctypes
import errno
import hashlib
import json
import os
import pathlib
import stat

SCHEMA = "findernotes-fn06-fixtures-v1"
NOTE = "com.findernotes.note.v1"
LIBC = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
LIBC.fgetxattr.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_void_p,
                          ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
LIBC.fgetxattr.restype = ctypes.c_ssize_t
LIBC.flistxattr.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
LIBC.flistxattr.restype = ctypes.c_ssize_t


def read_bytes(call):
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
    raise RuntimeError("Attribute changed during independent verification")


def fingerprint(path):
    fd = os.open(str(path), os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise ValueError("Expected a regular file with one link")
        digest = hashlib.sha256()
        while chunk := os.read(fd, 65536):
            digest.update(chunk)
        names = read_bytes(lambda buffer, size: LIBC.flistxattr(fd, buffer, size, 0))
        attrs = {}
        for name in names.split(b"\0"):
            if name:
                value = read_bytes(lambda buffer, size: LIBC.fgetxattr(fd, name, buffer, size, 0, 0))
                attrs[name.decode()] = value.hex()
        current = os.stat(path, follow_symlinks=False)
        if (info.st_dev, info.st_ino) != (current.st_dev, current.st_ino):
            raise ValueError("File identity changed while checking")
        return {"mediaSHA256": digest.hexdigest(), "xattrHex": dict(sorted(attrs.items())),
                "device": info.st_dev, "inode": info.st_ino, "mode": stat.S_IMODE(info.st_mode)}
    finally:
        os.close(fd)


def verify(root, expected_notes):
    root = pathlib.Path(root).resolve(strict=True)
    if not root.name.startswith("findernotes-fn06-"):
        raise ValueError("Not an FN-06 fixture root")
    marker = json.loads((root / ".fn06-owned.json").read_text())
    before = json.loads((root / "before.json").read_text())
    for document in (marker, before):
        if document["schema"] != SCHEMA or document["root"] != str(root):
            raise ValueError("Fixture ownership or schema mismatch")
    if before["runID"] != marker["runID"]:
        raise ValueError("Fixture run ID mismatch")
    if (root / "work").is_symlink():
        raise ValueError("Work directory is a symbolic link")
    if set(expected_notes) - set(before["files"]):
        raise ValueError("Expected-note entry does not match fixture inventory")
    checks = []
    for name, original in before["files"].items():
        if pathlib.Path(name).name != name or name in (".", ".."):
            raise ValueError("Invalid fixture name")
        try:
            current = fingerprint(root / "work" / name)
        except (OSError, ValueError, RuntimeError) as error:
            checks.append({"file": name, "readSucceeded": False, "error": str(error)})
            continue
        expected = dict(original["xattrHex"])
        note = expected_notes.get(name, expected.get(NOTE))
        if note is None:
            expected.pop(NOTE, None)
        else:
            expected[NOTE] = note
        checks.append({"file": name, "readSucceeded": True,
                       "modeMatches": original["mode"] == current["mode"],
                       "identityMatches": (original["device"], original["inode"]) ==
                                          (current["device"], current["inode"]),
                       "mediaSHA256Matches": original["mediaSHA256"] == current["mediaSHA256"],
                       "noteMatches": current["xattrHex"].get(NOTE) == expected.get(NOTE),
                       "unrelatedXattrsMatch": {k: v for k, v in current["xattrHex"].items() if k != NOTE} ==
                                                {k: v for k, v in expected.items() if k != NOTE},
                       "actualNoteHex": current["xattrHex"].get(NOTE)})
    failures = [check["file"] for check in checks if not all(value for key, value in check.items()
                if key in ("readSucceeded", "modeMatches", "identityMatches", "mediaSHA256Matches", "noteMatches", "unrelatedXattrsMatch"))]
    return {"schema": SCHEMA, "root": str(root), "runID": marker["runID"],
            "status": "passed" if not failures else "failed", "failures": failures,
            "fixtureMutationsByVerifier": [], "checks": checks}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root")
    parser.add_argument("--expect-note", action="append", default=[], metavar="NAME=HEX",
                        help="Expected raw note bytes in hex; use NAME=missing for no attribute")
    args = parser.parse_args()
    expected = {}
    for item in args.expect_note:
        name, separator, value = item.partition("=")
        if not separator or name in expected:
            raise ValueError("Expected one unique NAME=HEX per --expect-note")
        expected[name] = None if value == "missing" else bytes.fromhex(value).hex()
    result = verify(args.root, expected)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, RuntimeError) as error:
        print(json.dumps({"status": "failed", "error": str(error)}, ensure_ascii=False))
        raise SystemExit(1)
