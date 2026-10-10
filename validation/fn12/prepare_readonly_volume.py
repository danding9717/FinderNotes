#!/usr/bin/env python3
"""Prepare and mount a dedicated read-only-volume preflight app; never launch it.

This copies the existing independent build-12 fixture, retains its test public
key, changes only the review identity, and signs locally. No Keychain operation,
update archive, installer interaction, or production path is involved.
"""

import json
import os
import plistlib
import subprocess
from pathlib import Path


def run(*args):
    return subprocess.run(args, check=True, capture_output=True).stdout


def main():
    repository = Path(__file__).resolve().parents[2]
    source = repository / ".build/FN12ReadOnlyValidation/versions/12/FN12 ReadOnly Review.app"
    output = repository / ".build/FN12ReadOnlyVolumeValidation"
    if output.exists() or output.is_symlink():
        raise SystemExit(f"Refusing to replace existing fixture: {output}")
    source_info = plistlib.loads((source / "Contents/Info.plist").read_bytes())
    if (source_info.get("CFBundleIdentifier") != "com.findernotes.FinderNotes.FN12ReadOnlyReview"
            or source_info.get("CFBundleVersion") != "12"):
        raise SystemExit("Source must be the existing isolated readonly build 12.")
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(source))
    app_name = "FN12 ReadOnly Volume Review.app"
    identity = "com.findernotes.FinderNotes.FN12ReadOnlyVolumeReview"
    app = output / "staging" / app_name
    app.parent.mkdir(parents=True)
    run("/usr/bin/ditto", str(source), str(app))
    info = dict(source_info)
    info.update({
        "CFBundleIdentifier": identity,
        "CFBundleDisplayName": "FN12 ReadOnly Volume Review",
        "CFBundleName": "FN12 ReadOnly Volume Review",
        # Existing localhost test server; Sparkle's readonly-volume check aborts
        # before loading the feed. This fixture does not test downloading/installing.
        "SUFeedURL": "http://localhost:18775/appcast.xml",
        "NSServices": [{
            "NSMenuItem": {"default": "FN12 测试只读卷预检（隔离副本）"},
            "NSMessage": "receiveFiles", "NSPortName": "FinderNotesFN12ReadOnlyVolumeReview",
            "NSRequiredContext": {},
            "NSSendTypes": ["public.file-url", "NSFilenamesPboardType"], "NSTimeout": "10000",
        }],
    })
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    run("/usr/bin/codesign", "--force", "--sign", "-", str(app))
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(app))
    image = output / "FN12-ReadOnly-Preflight.dmg"
    run("/usr/bin/hdiutil", "create", "-format", "UDRO", "-srcfolder", str(app.parent),
        "-volname", "FN12 ReadOnly Preflight", str(image))
    mount = output / "Mount"
    mount.mkdir()
    attached = plistlib.loads(run("/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse",
                                 "-mountpoint", str(mount), "-plist", str(image)))
    (output / "attach.plist").write_bytes(plistlib.dumps(attached))
    mounted_entities = [entity for entity in attached.get("system-entities", [])
                        if entity.get("mount-point") == str(mount)]
    if len(mounted_entities) != 1:
        raise SystemExit("Image attached, but exact expected mount was not uniquely reported; inspect attach.plist.")
    device = mounted_entities[0]["dev-entry"]
    disk = plistlib.loads(run("/usr/sbin/diskutil", "info", "-plist", str(mount)))
    (output / "disk-info.plist").write_bytes(plistlib.dumps(disk))
    readonly_volume = disk.get("WritableVolume") is False
    readonly_media = disk.get("WritableMedia") is False
    readonly_stat = bool(os.statvfs(mount).f_flag & os.ST_RDONLY)
    if not (readonly_volume and readonly_media and readonly_stat):
        raise SystemExit("Mounted fixture did not report ReadOnlyVolume=true; do not launch it.")
    mounted_app = mount / app_name
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(mounted_app))
    manifest = {"purpose": "read-only-volume manual-check preflight only; no installation",
                "identity": identity, "version": "0.1.1", "build": "12",
                "app": str(mounted_app), "image": str(image), "mount": str(mount),
                "device": device, "readOnlyVolume": readonly_volume,
                "readOnlyMedia": readonly_media, "statvfsReadOnly": readonly_stat, "feedURL": info["SUFeedURL"],
                "publicKey": info["SUPublicEDKey"], "launched": False}
    (output / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(manifest, ensure_ascii=False, indent=2))
    print("Prepared and attached only. No app launched, no Keychain access, no authorization interaction.")


if __name__ == "__main__":
    main()
