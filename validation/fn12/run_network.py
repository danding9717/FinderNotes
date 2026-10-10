#!/usr/bin/env python3
"""Compile a no-UI real Sparkle harness and run network/error cases without installation."""
import json
import os
import plistlib
import subprocess
import sys
import time
from pathlib import Path


def main():
    project = Path(__file__).resolve().parents[2]
    root = project / ".build" / "FN12Validation"
    network = root / "network"
    app = network / "FN12 Network Checks.app"
    binary = app / "Contents" / "MacOS" / "FN12NetworkChecks"
    binary.parent.mkdir(parents=True, exist_ok=True)
    framework = project / ".build" / "FN12Dependencies" / "Sparkle" / "Sparkle.xcframework" / "macos-arm64_x86_64"
    environment = dict(os.environ, DEVELOPER_DIR=os.environ.get("FINDERNOTES_DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer"))
    subprocess.run(["xcrun", "clang", "-fobjc-arc", "-fblocks", "-F", str(framework),
                    "-framework", "Sparkle", "-framework", "AppKit", "-Wl,-rpath,@executable_path/../Frameworks",
                    str(project / "validation" / "fn12" / "NativeNetworkChecks.m"), "-o", str(binary)],
                   env=environment, check=True)
    embedded = app / "Contents" / "Frameworks" / "Sparkle.framework"
    if not embedded.exists():
        embedded.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["/usr/bin/ditto", str(framework / "Sparkle.framework"), str(embedded)], check=True)
    public_key = (root / "public-key.txt").read_text().strip()
    cases = ("update", "latest", "local-ahead", "404", "invalid", "offline", "timeout", "bad-signature", "corrupt", "slow-download")
    server = subprocess.Popen([sys.executable, "-B", str(project / "validation" / "fn12" / "network_server.py")],
                              stdout=(network / "server.log").open("w"), stderr=subprocess.STDOUT)
    results = []
    try:
        time.sleep(.3)
        if server.poll() is not None:
            raise SystemExit("Independent network fixture server failed to start; see server.log")
        for case in cases:
            port = 18774 if case == "offline" else 18773
            identity = "com.findernotes.FinderNotes.FN12NetworkChecks." + case
            info = {"CFBundleExecutable": binary.name, "CFBundleIdentifier": identity,
                    "CFBundleName": "FN12 Network Checks", "CFBundlePackageType": "APPL",
                    "CFBundleShortVersionString": "0.1.1", "CFBundleVersion": "12",
                    "NSPrincipalClass": "NSApplication", "LSUIElement": True,
                    "SUFeedURL": f"http://localhost:{port}/case/{case}", "SUPublicEDKey": public_key,
                    "SUEnableAutomaticChecks": False, "SUAllowsAutomaticUpdates": False,
                    "SUAutomaticallyUpdate": False, "SUVerifyUpdateBeforeExtraction": True,
                    "NSAppTransportSecurity": {"NSExceptionDomains": {"localhost": {"NSExceptionAllowsInsecureHTTPLoads": True}}}}
            with (app / "Contents" / "Info.plist").open("wb") as stream:
                plistlib.dump(info, stream)
            subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(app)], check=True, capture_output=True)
            subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True, capture_output=True)
            began = time.monotonic()
            completed = subprocess.run([str(binary), case], capture_output=True, text=True, timeout=85)
            (network / f"{case}.stdout.json").write_text(completed.stdout)
            (network / f"{case}.stderr.log").write_text(completed.stderr)
            try:
                result = json.loads(completed.stdout)
            except json.JSONDecodeError:
                result = {"case": case, "passed": False, "failure": "non-JSON harness result", "exitCode": completed.returncode}
            result["processExitCode"] = completed.returncode
            results.append(result)
            print(f"{case}: {'PASS' if result.get('passed') else 'FAIL'} ({time.monotonic()-began:.1f}s)", flush=True)
        (network / "results.json").write_text(json.dumps(results, ensure_ascii=False, indent=2) + "\n")
    finally:
        server.terminate()
        server.wait(timeout=5)
    passed = sum(result.get("passed", False) for result in results)
    print(f"RESULT: {passed} passed / {len(results)-passed} failed", flush=True)
    raise SystemExit(0 if passed == len(results) else 1)


if __name__ == "__main__":
    main()
