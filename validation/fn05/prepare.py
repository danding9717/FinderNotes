#!/usr/bin/env python3
"""Create a fresh, synthetic FN-05 PNG/MOV fixture root."""

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

from verify import NOTE, SCHEMA, fingerprint


def png_chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))


def set_xattr(path, name, data):
    subprocess.run(["/usr/bin/xattr", "-wx", name, data.hex(), str(path)], check=True)


def main():
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise SystemExit("ffmpeg is required to create a real synthetic MOV")
    root = pathlib.Path(tempfile.mkdtemp(prefix="findernotes-fn05-")).resolve()
    work = root / "work"
    work.mkdir()
    image = b"\x89PNG\r\n\x1a\n"
    image += png_chunk(b"IHDR", struct.pack(">IIBBBBB", 8, 8, 8, 2, 0, 0, 0))
    image += png_chunk(b"IDAT", zlib.compress((b"\0" + b"\x20\x80\xff" * 8) * 8))
    image += png_chunk(b"IEND", b"")
    for name in ("normal.png", "empty.png", "missing.png", "conflict.png"):
        (work / name).write_bytes(image)
    subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
                    "color=c=blue:s=16x16:r=1:d=1", "-c:v", "mpeg4", "-n",
                    str(work / "normal.mov")], check=True)
    notes = {"normal.png": "FN05 图片笔记：中文🙂\n  首尾空白  \n".encode(),
             "normal.mov": "FN05 视频笔记：中文🚀\n视频第二行\n".encode(),
             "empty.png": b"", "conflict.png": "FN05 原有正文".encode()}
    for path in sorted(work.iterdir()):
        set_xattr(path, "com.findernotes.fn05.sentinel", b"preserve-fn05\x00\xff")
        comment = plistlib.dumps("FN05 构造的 Finder 注释 " + path.name, fmt=plistlib.FMT_BINARY)
        set_xattr(path, "com.apple.metadata:kMDItemFinderComment", comment)
        if path.name in notes:
            set_xattr(path, NOTE, notes[path.name])
    subprocess.run(["/bin/cp", "-p", str(work / "normal.png"), str(work / "copy.png")], check=True)
    marker = {"schema": SCHEMA, "root": str(root), "runID": str(uuid.uuid4())}
    (root / ".fn05-owned.json").write_text(json.dumps(marker, ensure_ascii=False, indent=2) + "\n")
    before = dict(marker, files={path.name: fingerprint(path) for path in sorted(work.iterdir())})
    (root / "before.json").write_text(json.dumps(before, ensure_ascii=False, indent=2) + "\n")
    print(root)


if __name__ == "__main__":
    main()
