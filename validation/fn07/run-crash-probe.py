#!/usr/bin/env python3
"""Run a real SIGKILL/reopen probe of production recovery storage, without App/Finder UI.

Only newly generated synthetic bytes are used. The only killed PID is this runner's
own live Popen child. All resources and a hash-only evidence report are retained.
"""

import argparse
import datetime
import hashlib
import json
import os
import pathlib
import platform
import selectors
import signal
import subprocess
import tempfile
import uuid

from prepare import png, set_attribute
from verify import NOTE, SENTINEL, fingerprint

SCHEMA = "findernotes-fn07-process-crash-v1"
BASELINE = "FN07 process probe baseline\n中文🙂\n".encode()
EXTERNAL = "FN07 process probe external version\n外部合成正文\n".encode()


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def metadata(path):
    observed = fingerprint(path)
    attrs = observed.pop("xattrHex")
    observed["xattrs"] = {
        name: {"byteCount": len(bytes.fromhex(value)), "sha256": sha256(bytes.fromhex(value))}
        for name, value in attrs.items()
    }
    observed["noteState"] = "missing" if NOTE not in attrs else "empty" if attrs[NOTE] == "" else "present"
    return observed


def captured(command, **kwargs):
    result = subprocess.run(command, capture_output=True, text=True, timeout=120, **kwargs)
    return {"command": [str(value) for value in command], "exitCode": result.returncode,
            "stdout": result.stdout, "stderr": result.stderr}


def write_report(path, report):
    path.parent.mkdir(parents=True, exist_ok=True)
    # Never overwrite a prior evidence file, including on a rerun.
    with path.open("x") as handle:
        json.dump(report, handle, ensure_ascii=False, indent=2)
        handle.write("\n")


def run(output):
    require(not output.exists(), "Evidence output already exists; choose a new --output path")
    project = pathlib.Path(__file__).resolve().parents[2]
    developer = pathlib.Path(os.environ.get("FINDERNOTES_DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer"))
    compiler = developer / "Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
    require(compiler.is_file(), "Full Xcode Swift compiler is unavailable")
    root = pathlib.Path(tempfile.mkdtemp(prefix="findernotes-fn07-process-")).resolve()
    for name in ("work", "archive", "evidence", "bin", "module-cache"):
        (root / name).mkdir(mode=0o700)
    marker = {"schema": SCHEMA, "root": str(root), "runID": str(uuid.uuid4())}
    (root / ".fn07-process-owned.json").write_text(json.dumps(marker, indent=2) + "\n")
    report = dict(marker, startedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  status="failed", environment={"platform": platform.platform(), "machine": platform.machine(),
                                                "macOS": platform.mac_ver()[0]},
                  scope="real SIGKILL process and production recovery-store integration; no App/Finder UI",
                  limitations=["Only a record for which put returned is covered; unflushed keystrokes and sudden power loss are not covered.",
                               "Probe compares production NoteReader identity and baseline; it does not exercise App/Finder recovery UI.",
                               "All media and note text are synthetic; no real material is read or changed."],
                  killedPIDs=[], inspections=[])
    child = None
    try:
        env = os.environ.copy()
        env["DEVELOPER_DIR"] = str(developer)
        sdk = subprocess.run(["/usr/bin/xcrun", "--show-sdk-path"], capture_output=True, text=True,
                             check=True, env=env).stdout.strip()
        sources = [project / "FinderNotes/NoteReader.swift", project / "FinderNotes/DraftRecoveryStore.swift",
                   project / "validation/fn07/crash_probe.swift"]
        report["sources"] = [{"path": str(path), "sha256": sha256(path.read_bytes())} for path in sources]
        report["compilerVersion"] = captured([str(compiler), "--version"], env=env)
        binary = root / "bin/fn07-crash-probe"
        command = [str(compiler), "-O", "-whole-module-optimization", "-parse-as-library", "-swift-version", "6",
                   "-sdk", sdk, "-module-cache-path", str(root / "module-cache"),
                   *map(str, sources), "-o", str(binary)]
        report["compile"] = captured(command, env=env)
        report["releaseSemantics"] = {"optimization": "-O", "DEBUGDefined": False,
                                      "productionSourcesUnmodifiedByProbe": True}
        require(report["compile"]["exitCode"] == 0, "Probe compilation failed; see compile diagnostics")
        target = root / "work/original.png"
        media = png(96, 54)
        with target.open("xb") as handle:
            handle.write(media)
        set_attribute(target, NOTE, BASELINE)
        set_attribute(target, SENTINEL, b"fn07-process-sentinel\x00\xff")
        report["beforeSeed"] = metadata(target)
        record_id = str(uuid.uuid4()).upper()
        seed_command = [str(binary), "seed", str(root), record_id]
        child = subprocess.Popen(seed_command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 text=True, bufsize=1, env=env)
        require(child.stdout is not None, "Child stdout is unavailable")
        with selectors.DefaultSelector() as selector:
            selector.register(child.stdout, selectors.EVENT_READ)
            require(bool(selector.select(timeout=20)), "Timed out waiting for published-record readiness")
            ready_line = child.stdout.readline()
        ready = json.loads(ready_line)
        require(ready.get("event") == "ready" and ready.get("pid") == child.pid and
                ready.get("recordID") == record_id and ready.get("putReturned") is True,
                "Child did not confirm the expected completed publication")
        record_path = root / "Recovery/v1" / (record_id + ".json")
        published = record_path.read_bytes()
        report["seed"] = {"command": seed_command, "pid": child.pid, "readyStdout": ready_line,
                          "ready": ready, "publishedRecordByteCount": len(published),
                          "publishedRecordSHA256": sha256(published)}
        require(child.poll() is None, "Child exited before the requested SIGKILL")
        killed_pid = child.pid
        # Popen.kill targets this still-live child, whose PID cannot be recycled before wait/reap.
        child.kill()
        remaining_stdout, stderr = child.communicate(timeout=20)
        report["killedPIDs"].append(killed_pid)
        report["seed"].update({"requestedSignal": "SIGKILL", "signalNumber": signal.SIGKILL,
                               "exitCode": child.returncode, "terminatedBySIGKILL": child.returncode == -signal.SIGKILL,
                               "remainingStdout": remaining_stdout, "stderr": stderr})
        require(child.returncode == -signal.SIGKILL, "Child was not observed to exit from SIGKILL")
        require(remaining_stdout == "" and stderr == "", "Child emitted unexpected additional output")
        report["afterKill"] = metadata(target)
        require(report["afterKill"] == report["beforeSeed"], "Seeding or killing changed the formal target")

        def inspect(case):
            before = metadata(target)
            record_before = record_path.read_bytes()
            result = captured([str(binary), "inspect", str(root), record_id, case], env=env)
            require(result["exitCode"] == 0, "Recovery inspector returned failure: " + case)
            observed = json.loads(result["stdout"])
            after = metadata(target)
            unchanged_record = record_path.read_bytes() == record_before == published
            result.update({"result": observed, "targetBefore": before, "targetAfter": after,
                           "targetUnchangedByInspection": before == after,
                           "recoveryFileUnchangedByInspection": unchanged_record,
                           "recoveryFileSHA256": sha256(record_path.read_bytes())})
            report["inspections"].append(result)
            require(observed.get("casePassed") is True and observed.get("recordID") == record_id,
                    "Recovery inspection did not match expectations: " + case)
            require(before == after and unchanged_record, "Read-only recovery inspection changed source or record")

        inspect("unchanged")
        set_attribute(target, NOTE, EXTERNAL)
        report["externalMutation"] = {"operation": "replace owned note xattr with known synthetic external bytes",
                                      "after": metadata(target)}
        inspect("externalChanged")
        archive = root / "archive/original-before-replacement.png"
        target.rename(archive)
        with target.open("xb") as handle:
            handle.write(media)
        set_attribute(target, NOTE, BASELINE)
        set_attribute(target, SENTINEL, b"fn07-process-sentinel\x00\xff")
        report["replacementMutation"] = {"operation": "retain original and create same-path copy of original media/baseline",
                                         "archivedOriginal": str(archive), "archive": metadata(archive),
                                         "replacement": metadata(target)}
        require(report["replacementMutation"]["replacement"]["mediaSHA256"] == report["beforeSeed"]["mediaSHA256"],
                "Replacement media must match the original synthetic bytes")
        require(report["replacementMutation"]["replacement"]["xattrs"] == report["beforeSeed"]["xattrs"],
                "Replacement xattrs must match the original baseline exactly")
        inspect("replaced")
        report["status"] = "passed"
    except Exception as error:
        report["failure"] = {"type": type(error).__name__, "message": str(error)}
    finally:
        if child is not None and child.poll() is None:
            owned_pid = child.pid
            child.kill()
            child.communicate(timeout=20)
            report["killedPIDs"].append(owned_pid)
            report["failureCleanup"] = {"pid": owned_pid, "exitCode": child.returncode,
                                        "onlyOwnSpawnedChild": True}
        report["finishedAt"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        report["resourcesRetained"] = True
        write_report(root / "evidence/process-crash.json", report)
        write_report(output, report)
    print(json.dumps({"status": report["status"], "root": str(root), "evidence": str(output),
                      "processExitCode": report.get("seed", {}).get("exitCode"),
                      "inspections": len(report["inspections"])}, ensure_ascii=False))
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=pathlib.Path,
                        default=pathlib.Path(__file__).resolve().parents[2] / "docs/evidence/fn07/process-crash.json")
    arguments = parser.parse_args()
    raise SystemExit(run(arguments.output.resolve()))
