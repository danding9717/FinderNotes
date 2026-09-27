#!/usr/bin/env python3
"""Create a NEW FN-07 fixture directory using synthetic media bytes only."""
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

from verify import NOTE, SCHEMA, SENTINEL, fingerprint


def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))


def png(width, height):
    rows = [b"\0" + b"".join(bytes((x * 255 // width, y * 255 // height, 170))
                              for x in range(width)) for y in range(height)]
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(b"".join(rows))) + chunk(b"IEND", b""))


def set_attribute(path, name, data):
    subprocess.run(["/usr/bin/xattr", "-wx", name, data.hex(), str(path)], check=True)


def prepare():
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise RuntimeError("ffmpeg is required to create the synthetic MOV; no fixtures created")
    root = pathlib.Path(tempfile.mkdtemp(prefix="findernotes-fn07-")).resolve()
    work = root / "work"
    for directory in (work, root / "archive", root / "evidence"):
        directory.mkdir(mode=0o700)
    wide = png(640, 360)
    for name in ("recovery.png", "conflict.png", "deletion.png", "unrelated.png", "replace.png",
                 "moved.png", "empty.png", "missing.png", "copy-source.png", "readonly.png"):
        (work / name).write_bytes(wide)
    (work / "portrait.png").write_bytes(png(240, 480))
    subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
                    "testsrc2=size=480x270:rate=24:duration=30", "-f", "lavfi", "-i",
                    "sine=frequency=440:sample_rate=44100:duration=30", "-af", "volume=0.05",
                    "-c:v", "mpeg4", "-c:a", "aac", "-shortest", "-n", str(work / "audio.mov")], check=True)
    for path in sorted(work.iterdir()):
        set_attribute(path, SENTINEL, b"preserve-fn07\x00\xff")
        set_attribute(path, "com.apple.metadata:kMDItemFinderComment",
                      plistlib.dumps("FN07 构造的原生注释 " + path.name, fmt=plistlib.FMT_BINARY))
        if path.name != "missing.png":
            note = b"" if path.name == "empty.png" else ("FN07 原有笔记 " + path.name + "\n中文🙂\n").encode()
            set_attribute(path, NOTE, note)
    # Same media AND note bytes, independently created file identity.
    subprocess.run(["/bin/cp", "-p", str(work / "copy-source.png"), str(work / "copy.png")], check=True)
    os.chmod(work / "readonly.png", 0o444)
    marker = {"schema": SCHEMA, "root": str(root), "runID": str(uuid.uuid4())}
    (root / ".fn07-owned.json").write_text(json.dumps(marker, ensure_ascii=False, indent=2) + "\n")
    before = dict(marker, files={p.name: fingerprint(p) for p in sorted(work.iterdir())})
    (root / "before.json").write_text(json.dumps(before, ensure_ascii=False, indent=2) + "\n")
    return root


if __name__ == "__main__":
    print(prepare())
