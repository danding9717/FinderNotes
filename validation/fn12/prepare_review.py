#!/usr/bin/env python3
"""Prepare two isolated, Sparkle-signed FN12 review builds without launching either.

The standard setup can create an independent FN12 review key in Keychain;
IME and acceptance variants only read that existing key.
No production feed, key, installed app, recovery directory or service is changed.
"""

import argparse
import json
import plistlib
import re
import subprocess
from pathlib import Path


KEY_ACCOUNT = "com.findernotes.FN12Review"
VARIANTS = {
    "standard": {"identity": "com.findernotes.FinderNotes.FN12Review", "appName": "FinderNotes FN12 Review.app",
                 "displayName": "FinderNotes FN12 Review", "directory": "FN12Validation", "port": 18772,
                 "archivePrefix": "FinderNotes-FN12Review", "serviceName": "FN12 测试更新（隔离副本）",
                 "servicePort": "FinderNotesFN12Review"},
    "readonly": {"identity": "com.findernotes.FinderNotes.FN12ReadOnlyReview", "appName": "FN12 ReadOnly Review.app",
                 "displayName": "FN12 ReadOnly Review", "directory": "FN12ReadOnlyValidation", "port": 18775,
                 "archivePrefix": "FinderNotes-FN12ReadOnlyReview", "serviceName": "FN12 测试只读更新（隔离副本）",
                 "servicePort": "FinderNotesFN12ReadOnlyReview"},
    "ime": {"identity": "com.findernotes.FinderNotes.FN12IMEReview", "appName": "FN12 IME Review.app",
            "displayName": "FN12 IME Review", "directory": "FN12IMEValidation", "port": 18776,
            "archivePrefix": "FinderNotes-FN12IMEReview", "serviceName": "FN12 测试中文输入更新（隔离副本）",
            "servicePort": "FinderNotesFN12IMEReview"},
    "acceptance": {"identity": "com.findernotes.FinderNotes.FN12Acceptance",
                   "appName": "FinderNotes 更新验收.app", "displayName": "FinderNotes 更新验收",
                   "directory": "FN12Acceptance", "port": 18777,
                   "archivePrefix": "FinderNotes-FN12Acceptance",
                   "serviceName": "FinderNotes 更新验收（隔离副本）",
                   "servicePort": "FinderNotesFN12Acceptance"},
}


def run(*args):
    return subprocess.run(args, check=True, text=True, capture_output=True).stdout.strip()


def sign_update(tool, path):
    output = run(str(tool), "--account", KEY_ACCOUNT, str(path))
    match = re.search(r'sparkle:edSignature="([^"]+)"', output)
    if not match:
        raise SystemExit("Sparkle sign_update returned no EdDSA signature.")
    return {"signature": match.group(1), "length": path.stat().st_size}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input-app", required=True, type=Path)
    parser.add_argument("--sparkle-tools", required=True, type=Path)
    parser.add_argument("--variant", choices=VARIANTS, default="standard")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--port", type=int)
    args = parser.parse_args()
    variant = VARIANTS[args.variant]
    identity, app_name = variant["identity"], variant["appName"]
    source = args.input_app.resolve()
    allowed = Path(__file__).resolve().parents[2] / ".build" / variant["directory"]
    output = args.output.resolve() if args.output else allowed.resolve()
    port = args.port if args.port is not None else variant["port"]
    if output != allowed.resolve():
        raise SystemExit(f"Review output must be this worktree's .build/{variant['directory']}.")
    if args.variant == "acceptance" and (allowed.exists() or allowed.is_symlink()):
        raise SystemExit(f"Refusing to use an existing acceptance output: {allowed}")
    if args.variant != "standard" and port != variant["port"]:
        raise SystemExit(f"The {args.variant} variant uses fixed localhost port {variant['port']}.")
    if source == output or output in source.parents or not source.is_dir():
        raise SystemExit("Provide the built production app outside the review output directory.")
    if not 1024 <= port <= 65535:
        raise SystemExit("Use an unprivileged localhost port between 1024 and 65535.")
    for build in (12, 13):
        for existing in (output / "versions" / str(build) / app_name,
                         output / "feed-assets" / f"{variant['archivePrefix']}-{build}.zip"):
            if existing.exists():
                raise SystemExit(f"Refusing to replace existing review artifact: {existing}")
    if (output / "Installed" / app_name).exists():
        raise SystemExit("Refusing to replace an installed review app.")
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(source))
    tools = args.sparkle_tools.resolve()
    # The official tool reuses this account if it already exists, and never prints its private key.
    key_arguments = ("-p",) if args.variant in ("ime", "acceptance") else ()
    key_output = run(str(tools / "generate_keys"), "--account", KEY_ACCOUNT, *key_arguments)
    keys = re.findall(r"[A-Za-z0-9+/]{43}=", key_output)
    if not keys:
        raise SystemExit("Sparkle generate_keys returned no public key.")
    public_key = keys[-1]
    output.mkdir(parents=True, exist_ok=args.variant != "acceptance")
    (output / "public-key.txt").write_text(public_key + "\n")
    archives = output / "feed-assets"
    archives.mkdir(exist_ok=True)
    manifest = {"identity": identity, "keyAccount": KEY_ACCOUNT, "port": port, "variant": args.variant,
                "displayName": variant["displayName"],
                "feedURL": f"http://localhost:{port}/appcast.xml", "archives": {}}
    for build, version in ((12, "0.1.1"), (13, "0.1.2")):
        app = output / "versions" / str(build) / app_name
        if app.exists():
            raise SystemExit(f"Refusing to replace existing review version: {app}")
        app.parent.mkdir(parents=True, exist_ok=True)
        run("/usr/bin/ditto", str(source), str(app))
        plist = app / "Contents" / "Info.plist"
        with plist.open("rb") as stream:
            info = plistlib.load(stream)
        info.update({
            "CFBundleIdentifier": identity,
            "CFBundleDisplayName": variant["displayName"],
            "CFBundleName": variant["displayName"],
            "CFBundleShortVersionString": version,
            "CFBundleVersion": str(build),
            "FinderNotesUpdatesEnabled": True,
            "SUFeedURL": manifest["feedURL"],
            "SUPublicEDKey": public_key,
            "SUEnableAutomaticChecks": False,
            "SUAutomaticallyUpdate": False,
            "SUAllowsAutomaticUpdates": False,
            "SUVerifyUpdateBeforeExtraction": True,
            "SURequireSignedFeed": False,
            "NSAppTransportSecurity": {"NSExceptionDomains": {"localhost": {
                "NSExceptionAllowsInsecureHTTPLoads": True,
                "NSIncludesSubdomains": False,
            }}},
            "NSServices": [{
                "NSMenuItem": {"default": variant["serviceName"]},
                "NSMessage": "receiveFiles", "NSPortName": variant["servicePort"],
                "NSRequiredContext": {},
                "NSSendTypes": ["public.file-url", "NSFilenamesPboardType"],
                "NSTimeout": "10000",
            }],
        })
        with plist.open("wb") as stream:
            plistlib.dump(info, stream)
        # Re-sign only the modified review host. Embedded Sparkle's original nested signatures remain intact.
        run("/usr/bin/codesign", "--force", "--sign", "-", str(app))
        run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(app))
        archive = archives / f"{variant['archivePrefix']}-{build}.zip"
        if archive.exists():
            raise SystemExit(f"Refusing to replace an existing signed archive: {archive}")
        run("/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(archive))
        details = sign_update(tools / "sign_update", archive)
        details.update({"filename": archive.name, "version": str(build), "shortVersion": version})
        manifest["archives"][str(build)] = details
    corrupt = archives / f"{variant['archivePrefix']}-corrupt.zip"
    corrupt.write_bytes(b"FN12 deliberately invalid ZIP; validation fixture only.\n")
    manifest["corruptLength"] = corrupt.stat().st_size
    manifest["corruptFilename"] = corrupt.name
    installed = output / "Installed" / app_name
    if installed.exists():
        raise SystemExit(f"Refusing to replace an installed review app: {installed}")
    installed.parent.mkdir(exist_ok=True)
    run("/usr/bin/ditto", str(output / "versions" / "12" / app_name), str(installed))
    manifest["installedApp"] = str(installed)
    (output / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    (output / "state.json").write_text('{"case": "update"}\n')
    print(json.dumps({"installedApp": str(installed), "identity": identity,
                      "feedURL": manifest["feedURL"], "keyAccount": KEY_ACCOUNT,
                      "versions": [12, 13]}, ensure_ascii=False, indent=2))
    print("Prepared only. No app was launched and no Finder service was registered.")


if __name__ == "__main__":
    main()
