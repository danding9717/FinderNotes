#!/usr/bin/env python3
"""Record the exact M1 validation executable and PID during Finder UI checks."""

import argparse
import datetime
import json
import pathlib
import subprocess
import time


ROOT = pathlib.Path(__file__).resolve().parents[3]
APP = ROOT / ".build/DerivedData/Build/Products/Release/FinderNotes.app/Contents/MacOS/FinderNotes"
EVENTS = pathlib.Path(__file__).with_name("ui-process-cycles.jsonl")


def matching_processes():
    output = subprocess.check_output(["ps", "-axo", "pid=,command="], text=True)
    result = []
    executable = str(APP)
    for line in output.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and (parts[1] == executable or parts[1].startswith(executable + " ")):
            result.append({"pid": int(parts[0]), "executable": executable})
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cycle", type=int)
    parser.add_argument("phase", choices=("opened", "closed"))
    parser.add_argument("file")
    args = parser.parse_args()
    expected = 1 if args.phase == "opened" else 0
    started = time.monotonic()
    while True:
        processes = matching_processes()
        if len(processes) == expected or time.monotonic() - started >= 5:
            break
        time.sleep(0.1)
    record = {
        "cycle": args.cycle,
        "phase": args.phase,
        "file": args.file,
        "timestampUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "processes": processes,
        "expectedProcessCount": expected,
        "processCountMatches": len(processes) == expected,
        "dockIconCount": None,
        "dockObservation": "Dock AX -10005 and ScreenCaptureKit -3811",
    }
    with EVENTS.open("a", encoding="utf-8") as output:
        output.write(json.dumps(record, ensure_ascii=False) + "\n")
    print(json.dumps(record, ensure_ascii=False))
    return 0 if record["processCountMatches"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
