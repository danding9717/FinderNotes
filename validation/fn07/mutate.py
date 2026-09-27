#!/usr/bin/env python3
"""Apply deliberate external changes ONLY to inventoried FN-07 synthetic files.

This tool is for a sequential local fixture session; it is not an atomic CAS API.
Removed/replaced originals are retained under archive/ for evidence.
"""

import argparse
import json
import os
import subprocess
import uuid

from prepare import set_attribute
from verify import NOTE, SENTINEL, fingerprint, identity, owned_root


def mutate(value, name, action, hex_value=None):
    root, marker, before = owned_root(value)
    if name not in before["files"]:
        raise ValueError("File must be in this run's original inventory")
    path = root / "work" / name
    current = fingerprint(path)
    if identity(current) != identity(before["files"][name]):
        raise ValueError("Refusing to mutate a replaced or unconfirmed target")
    if current["mediaSHA256"] != before["files"][name]["mediaSHA256"]:
        raise ValueError("Refusing to mutate a target with changed media bytes")
    if hex_value is not None and action != "note":
        raise ValueError("--hex is only valid with the note action")
    archive = None
    if action == "note":
        body = bytes.fromhex(hex_value) if hex_value is not None else "FN07 外部版本\n仅合成验收正文🙂\n".encode()
        body.decode("utf-8", errors="strict")
        set_attribute(path, NOTE, body)
    elif action == "delete-note":
        subprocess.run(["/usr/bin/xattr", "-d", NOTE, str(path)], check=True)
    elif action == "unrelated":
        set_attribute(path, SENTINEL, b"fn07-external-unrelated-change\x00\xff")
    elif action in ("replace", "move"):
        archive = root / "archive" / (uuid.uuid4().hex + "-" + name)
        if action == "replace":
            replacement = root / "archive" / (uuid.uuid4().hex + "-replacement-" + name)
            # Deliberately reproduce both media and xattrs while changing identity.
            with replacement.open("xb") as handle:
                handle.write(path.read_bytes())
            for attribute, raw in current["xattrHex"].items():
                set_attribute(replacement, attribute, bytes.fromhex(raw))
            os.chmod(replacement, current["mode"])
            if identity(fingerprint(path)) != identity(current):
                raise ValueError("Target identity changed before replacement")
            path.rename(archive)
            replacement.rename(path)
        else:
            path.rename(archive)
    else:
        raise ValueError("Unsupported mutation action")
    after = fingerprint(path) if path.exists() else None
    result = {"schema": marker["schema"], "root": str(root), "runID": marker["runID"],
              "action": action, "file": name, "before": current, "after": after,
              "archivedOriginal": str(archive) if archive else None}
    # Only synthetic test content is written to this explicit evidence file.
    evidence = root / "evidence" / (uuid.uuid4().hex + "-mutation.json")
    evidence.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    return result | {"evidence": str(evidence)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root")
    parser.add_argument("file")
    parser.add_argument("action", choices=("note", "delete-note", "unrelated", "replace", "move"))
    parser.add_argument("--hex", help="Synthetic UTF-8 note bytes; empty string writes an empty attribute")
    args = parser.parse_args()
    print(json.dumps(mutate(args.root, args.file, args.action, args.hex), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
