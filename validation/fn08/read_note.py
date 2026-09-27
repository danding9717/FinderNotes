#!/usr/bin/env python3
"""Independently read the raw UTF-8 com.findernotes.note.v1 attribute on macOS.

The body has no wrapper, header or JSON schema. Missing, empty, invalid UTF-8 and
read failure are distinct outcomes. --export writes exactly the attribute bytes
to a new file only; it never overwrites or modifies the media. No Finder comment
or local recovery file is consulted. JSON on stdout is evidence, not note format.
"""

import argparse
import ctypes
import errno
import hashlib
import json
import os
import pathlib
import stat
import sys
import tempfile

NOTE = "com.findernotes.note.v1"
LIBC = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
LIBC.fgetxattr.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_void_p,
                          ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
LIBC.fgetxattr.restype = ctypes.c_ssize_t
LIBC.renamex_np.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
LIBC.renamex_np.restype = ctypes.c_int
RENAME_EXCL = 0x00000004


def read_note(path):
    result = {"path": str(pathlib.Path(path).absolute()), "attribute": NOTE,
              "format": "raw UTF-8, no wrapper", "mediaModified": False}
    fd = None
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
        initial = os.fstat(fd)
        if not stat.S_ISREG(initial.st_mode):
            raise ValueError("Expected a regular media file")
        name = NOTE.encode("ascii")
        data = None
        for _ in range(4):
            count = LIBC.fgetxattr(fd, name, None, 0, 0, 0)
            if count < 0:
                code = ctypes.get_errno()
                if code == errno.ENOATTR:
                    result["state"] = "missing"
                    break
                raise OSError(code, os.strerror(code))
            buffer = ctypes.create_string_buffer(max(1, count))
            actual = LIBC.fgetxattr(fd, name, buffer, len(buffer), 0, 0)
            if actual >= 0:
                data = buffer.raw[:actual]
                break
            code = ctypes.get_errno()
            if code != errno.ERANGE:
                raise OSError(code, os.strerror(code))
        else:
            raise RuntimeError("Attribute repeatedly changed during independent read")
        current = os.stat(path, follow_symlinks=False)
        if (initial.st_dev, initial.st_ino) != (current.st_dev, current.st_ino):
            raise RuntimeError("File identity changed during independent read")
        if data is not None:
            result.update(byteLength=len(data), rawHex=data.hex(),
                          sha256=hashlib.sha256(data).hexdigest())
            try:
                result.update(state="empty" if not data else "present", text=data.decode("utf-8"))
            except UnicodeDecodeError as error:
                result.update(state="invalid_utf8", error=str(error))
        return result, data
    except (OSError, ValueError, RuntimeError) as error:
        result.update(state="read_error", error=str(error), errno=getattr(error, "errno", None))
        return result, None
    finally:
        if fd is not None:
            os.close(fd)


def write_and_check(fd, data):
    offset = 0
    while offset < len(data):
        count = os.write(fd, data[offset:])
        if count <= 0:
            raise OSError(errno.EIO, "Temporary export write made no progress")
        offset += count
    os.fsync(fd)
    readback = read_descriptor(fd)
    if readback != data:
        raise OSError(errno.EIO, "Temporary export readback differs from intended bytes")


def read_descriptor(fd):
    os.lseek(fd, 0, os.SEEK_SET)
    result = bytearray()
    while chunk := os.read(fd, 65536):
        result.extend(chunk)
    return bytes(result)


def require_owned_path(fd, path, data):
    # Keep the descriptor open across publication; a pathname alone cannot prove
    # that our new file is still present. This is confirmation at this check,
    # not a promise against a later filesystem mutation.
    held = os.fstat(fd)
    named = os.lstat(path)
    if (not stat.S_ISREG(named.st_mode) or named.st_nlink != 1 or
            (held.st_dev, held.st_ino) != (named.st_dev, named.st_ino)):
        raise OSError(errno.ESTALE, "Export pathname no longer identifies the created file")
    if read_descriptor(fd) != data:
        raise OSError(errno.EIO, "Export readback differs from intended bytes")
    final = os.lstat(path)
    if (final.st_dev, final.st_ino, final.st_size, final.st_mtime_ns,
            final.st_ctime_ns, final.st_nlink) != (
            held.st_dev, held.st_ino, held.st_size, held.st_mtime_ns,
            held.st_ctime_ns, held.st_nlink):
        raise OSError(errno.ESTALE, "Export changed during publication confirmation")


def publish_exclusive(temporary, destination):
    if LIBC.renamex_np(os.fsencode(temporary), os.fsencode(destination), RENAME_EXCL) != 0:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code), str(destination))


def preserve_diagnostic(parent, destination, data):
    fd, filename = tempfile.mkstemp(prefix=f".{destination.name}.fn08-export-evidence-", dir=parent)
    try:
        write_and_check(fd, data)
        require_owned_path(fd, filename, data)
    finally:
        os.close(fd)
    return filename


def export_new_file(path, data):
    destination = pathlib.Path(path).absolute()
    result = {"path": str(destination), "byteLength": len(data),
              "sha256": hashlib.sha256(data).hexdigest(), "exclusiveCreate": True}
    fd, temporary = None, None
    published = False
    try:
        fd, temporary = tempfile.mkstemp(prefix=f".{destination.name}.fn08-export-", dir=destination.parent)
        result["temporaryPath"] = temporary
        write_and_check(fd, data)
        require_owned_path(fd, temporary, data)
        publish_exclusive(temporary, destination)
        published = True
        result["temporaryPath"] = None  # Rename consumed this pathname.
        require_owned_path(fd, destination, data)
        result.update(status="created", temporaryPath=None, readbackConfirmed=True,
                      finalPathIdentityConfirmed=True)
    except (OSError, ValueError, RuntimeError) as error:
        result.update(status="publication_unconfirmed" if published else "failed",
                      error=str(error), errno=getattr(error, "errno", None),
                      publicationAttemptCompleted=published)
        # Never unlink on failure: a concurrent actor may have replaced any path.
        # If rename succeeded, preserve an independent copy of intended bytes
        # so even deletion of the final pathname leaves usable diagnostic data.
        if published:
            try:
                result["evidencePath"] = preserve_diagnostic(destination.parent, destination, data)
            except (OSError, ValueError, RuntimeError) as evidence_error:
                result["evidencePreservationError"] = str(evidence_error)
    finally:
        if fd is not None:
            os.close(fd)
    return result


def inspect_and_export(media, destination=None):
    # Resolve /var versus /private/var, symlinks and '..' before touching source
    # bytes. Otherwise a moved source could be recreated as a text export.
    if destination is not None and pathlib.Path(media).resolve(strict=False) == pathlib.Path(destination).resolve(strict=False):
        return {"path": str(pathlib.Path(media).absolute()), "attribute": NOTE,
                "state": "not_read", "mediaModified": False,
                "export": {"status": "refused", "reason": "Source and export destination resolve to the same path"}}, 1
    result, data = read_note(media)
    if destination is not None:
        if result["state"] not in ("present", "empty"):
            result["export"] = {"status": "refused", "reason": "A readable UTF-8 note is required"}
        else:
            result["export"] = export_new_file(destination, data)
        if result["export"]["status"] != "created":
            return result, 1
    return result, 0 if result["state"] in ("present", "empty", "missing") else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("media", help="A regular media file; never written by this tool")
    parser.add_argument("--export", metavar="NEW_MARKDOWN", help="Create an independent raw-body snapshot; refuse existing destination")
    args = parser.parse_args()
    result, code = inspect_and_export(args.media, args.export)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return code


if __name__ == "__main__":
    sys.exit(main())
