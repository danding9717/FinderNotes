#!/usr/bin/env python3
"""Generate a fresh FN-04 UI-only fixture root; never read or overwrite existing media."""
import json
import os
import pathlib
import plistlib
import shutil
import struct
import subprocess
import tempfile
import uuid
import zlib

from verify import FILES, MARKER, SCHEMA, fingerprint, utc_now

NOTE = "com.findernotes.note.v1"


def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))


def write_new(path, data):
    with path.open("xb") as output:
        output.write(data)


def set_attribute(path, name, data):
    subprocess.run(["/usr/bin/xattr", "-wx", name, data.hex(), str(path)], check=True)


def main():
    ffmpeg = shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg"
    if not os.access(ffmpeg, os.X_OK):
        raise SystemExit("ffmpeg is required to generate a real synthetic MOV; nothing was created")
    root = pathlib.Path(tempfile.mkdtemp(prefix="findernotes-fn04-")).resolve()
    work = root / "work"
    work.mkdir()
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 8, 8, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress((b"\0" + b"\x20\x80\xff" * 8) * 8)) + chunk(b"IEND", b"")
    for name in FILES:
        if name.endswith(".png"):
            write_new(work / name, png)
    subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
                    "color=c=blue:s=16x16:r=1:d=1", "-c:v", "mpeg4", "-n", str(work / "normal.mov")], check=True)
    notes = {
        "normal.png": "FN04 图片笔记：中文🙂\n  保留首尾空白  \n".encode(),
        "normal.mov": "FN04 视频笔记：中文🚀\nMOV 热启动样本\n".encode(),
        "empty.png": b"", "invalid.png": b"\xff",
        "unreadable.png": "FN04 不可读样本：不能当作空笔记".encode(),
    }
    for name in FILES:
        path = work / name
        set_attribute(path, "com.findernotes.fn04.sentinel", b"preserve-me-fn04\x00\xff")
        comment = plistlib.dumps("FN04 原生 Finder 注释样本 " + name, fmt=plistlib.FMT_BINARY)
        set_attribute(path, "com.apple.metadata:kMDItemFinderComment", comment)
        if name in notes:
            set_attribute(path, NOTE, notes[name])
    fingerprints = {name: fingerprint(work / name) for name in FILES}
    os.chmod(work / "unreadable.png", 0)
    fingerprints["unreadable.png"]["mode"] = "0000"
    fingerprints["unreadable.png"]["contentCapturedBeforeApplyingMode000"] = True
    run_id = str(uuid.uuid4())
    common = {"schema": SCHEMA, "root": str(root), "runID": run_id, "createdAt": utc_now()}
    write_new(root / MARKER, (json.dumps(common, ensure_ascii=False, indent=2) + "\n").encode())
    before = dict(common, files=fingerprints,
                  boundary="Synthetic local fixtures only; native Finder comment display is not verified")
    write_new(root / "before.json", (json.dumps(before, ensure_ascii=False, indent=2) + "\n").encode())
    print(root)


if __name__ == "__main__":
    main()
