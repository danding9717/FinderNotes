#!/usr/bin/env python3
"""Observe selected local transfer tools using one NEW synthetic PNG only.

No existing media, mounted volume, backup, cloud folder or NAS is accessed.
The JSON report records each exact argv, output and before/after xattr bytes.
Observed preservation applies only to these commands and this local volume.
"""

import datetime
import json
import os
import pathlib
import platform
import plistlib
import subprocess
import sys
import tempfile
import time
import uuid

from prepare import png, set_attribute
from verify import NOTE, SENTINEL, fingerprint


def command(argv):
    started = datetime.datetime.now(datetime.timezone.utc).isoformat()
    clock = time.monotonic()
    result = subprocess.run(argv, capture_output=True, text=True)
    return {"argv": argv, "cwd": os.getcwd(), "startedUTC": started,
            "durationSeconds": round(time.monotonic() - clock, 3),
            "exitCode": result.returncode, "stdout": result.stdout, "stderr": result.stderr}


def compare(original, current):
    old = original["xattrHex"]
    new = current["xattrHex"]
    return {"sameVolume": original["device"] == current["device"],
            "mediaSHA256Matches": original["mediaSHA256"] == current["mediaSHA256"],
            "allXattrsMatch": old == new,
            "noteMatches": old.get(NOTE) == new.get(NOTE),
            "finderCommentMatches": old.get("com.apple.metadata:kMDItemFinderComment") ==
                                     new.get("com.apple.metadata:kMDItemFinderComment"),
            "sentinelMatches": old.get(SENTINEL) == new.get(SENTINEL),
            "missingAttributes": sorted(set(old) - set(new)),
            "addedAttributes": sorted(set(new) - set(old)),
            "changedAttributes": sorted(key for key in old.keys() & new.keys() if old[key] != new[key])}


def main():
    root = pathlib.Path(tempfile.mkdtemp(prefix="findernotes-fn08-transfer-")).resolve()
    marker = {"schema": "findernotes-fn08-transfer-v1", "root": str(root), "runID": str(uuid.uuid4())}
    (root / ".fn08-transfer-owned.json").write_text(json.dumps(marker, indent=2) + "\n")
    source_directory = root / "source"
    source_directory.mkdir(mode=0o700)
    source = source_directory / "synthetic.png"
    source.write_bytes(png(128, 72))
    set_attribute(source, NOTE, "FN08 独立传输实验\n原始 UTF-8 正文🙂\n".encode())
    set_attribute(source, SENTINEL, b"preserve-fn08-transfer\x00\xff")
    set_attribute(source, "com.apple.metadata:kMDItemFinderComment",
                  plistlib.dumps("FN08 合成 Finder 原生注释", fmt=plistlib.FMT_BINARY))
    original = fingerprint(source)
    cases = [
        ("same-volume-cp-p", [["/bin/cp", "-p", str(source), str(root / "cp.png")]], root / "cp.png"),
        ("same-volume-ditto", [["/usr/bin/ditto", "--rsrc", "--extattr", str(source), str(root / "ditto.png")]], root / "ditto.png"),
        ("system-ditto-zip-roundtrip", [
            ["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(source_directory), str(root / "ditto.zip")],
            ["/usr/bin/ditto", "-x", "-k", str(root / "ditto.zip"), str(root / "ditto-unpacked")]],
            root / "ditto-unpacked" / "source" / "synthetic.png"),
        ("python-standard-zip-roundtrip", [
            [sys.executable, "-m", "zipfile", "-c", str(root / "python.zip"), str(source)],
            [sys.executable, "-m", "zipfile", "-e", str(root / "python.zip"), str(root / "python-unpacked")]],
            root / "python-unpacked" / "synthetic.png"),
    ]
    observations = []
    for name, commands, destination in cases:
        executions = []
        for argv in commands:
            result = command(argv)
            executions.append(result)
            if result["exitCode"] != 0:
                break
        observation = {"case": name, "destination": str(destination), "commands": executions}
        try:
            current = fingerprint(destination)
            observation.update(status="observed", after=current, comparison=compare(original, current))
        except (OSError, ValueError, RuntimeError) as error:
            observation.update(status="observation_failed", error=str(error))
        observations.append(observation)
    final_source = fingerprint(source)
    report = dict(marker, recordedUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  environment={"macOS": platform.mac_ver()[0], "architecture": platform.machine(),
                               "python": sys.version, "pythonExecutable": sys.executable},
                  source={"path": str(source), "before": original, "after": final_source,
                          "unchanged": original == final_source},
                  observations=observations,
                  scope="Fresh synthetic PNG; same local volume; exact recorded tool invocations only",
                  unverified=["Finder drag/drop and Archive Utility", "Time Machine and other backups",
                              "cross-volume or alternate-filesystem copies", "cloud sync", "NAS",
                              "messaging/email forwarding", "other compression tools/options",
                              "restore from a delivered archive on a different computer"],
                  conclusions=["Do not promise arbitrary transfers preserve custom notes.",
                               "Independent Markdown is a body snapshot, not synchronization or a second note store."])
    report["status"] = "completed" if original == final_source and all(
        item["status"] == "observed" and all(cmd["exitCode"] == 0 for cmd in item["commands"])
        for item in observations) else "incomplete"
    (root / "transfer.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report["status"] == "completed" else 1


if __name__ == "__main__":
    sys.exit(main())
