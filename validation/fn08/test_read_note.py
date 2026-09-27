#!/usr/bin/env python3
"""Isolated FN-08 independent-export regressions; preserves all synthetic evidence."""

import argparse
import datetime
import errno
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import read_note as reader
from prepare import png, set_attribute
from verify import NOTE, SENTINEL, fingerprint


class ExportRegression(unittest.TestCase):
    root = Path(tempfile.mkdtemp(prefix="findernotes-fn08-read-final-")).resolve()
    observations = []

    def setUp(self):
        self.directory = self.root / self._testMethodName
        self.directory.mkdir(mode=0o700)
        self.source = self.directory / "synthetic.png"
        self.source.write_bytes(png(32, 18))
        self.body = "FN08 独立导出最终回归\n中文🙂\n".encode()
        set_attribute(self.source, NOTE, self.body)
        set_attribute(self.source, SENTINEL, b"fn08-read-final\x00\xff")
        self.before = fingerprint(self.source)
        self.observation = {"test": self._testMethodName, "source": str(self.source), "before": self.before}

    def tearDown(self):
        after = fingerprint(self.source)
        self.observation.update(after=after, sourceUnchanged=after == self.before)
        self.observations.append(self.observation)
        self.assertEqual(after, self.before)

    def cli(self, source, destination=None):
        argv = [sys.executable, str(Path(reader.__file__).resolve()), str(source)]
        if destination is not None:
            argv += ["--export", str(destination)]
        result = subprocess.run(argv, capture_output=True, text=True,
                                env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"))
        decoded = json.loads(result.stdout)
        self.observation.setdefault("commands", []).append(
            {"argv": argv, "exitCode": result.returncode, "stdout": result.stdout,
             "stderr": result.stderr, "result": decoded})
        return decoded, result.returncode

    def test_nonempty_export(self):
        destination = self.directory / "note.md"
        result, code = self.cli(self.source, destination)
        self.assertEqual(code, 0)
        self.assertEqual(result["export"]["status"], "created")
        self.assertTrue(result["export"]["finalPathIdentityConfirmed"])
        self.assertEqual(destination.read_bytes(), self.body)

    def test_empty_export(self):
        set_attribute(self.source, NOTE, b"")
        self.before = fingerprint(self.source)
        self.observation["before"] = self.before
        destination = self.directory / "empty.md"
        result, code = self.cli(self.source, destination)
        self.assertEqual(code, 0)
        self.assertEqual(result["state"], "empty")
        self.assertEqual(result["export"]["status"], "created")
        self.assertEqual(destination.read_bytes(), b"")

    def test_missing_attribute(self):
        subprocess.run(["/usr/bin/xattr", "-d", NOTE, str(self.source)], check=True)
        self.before = fingerprint(self.source)
        self.observation["before"] = self.before
        destination = self.directory / "missing.md"
        result, code = self.cli(self.source, destination)
        self.assertEqual(code, 1)
        self.assertEqual(result["state"], "missing")
        self.assertEqual(result["export"]["status"], "refused")
        self.assertFalse(destination.exists())

    def test_existing_target_is_preserved(self):
        destination = self.directory / "existing.md"
        destination.write_bytes(b"existing unrelated content\n")
        before = fingerprint(destination)
        result, code = self.cli(self.source, destination)
        self.assertEqual(code, 1)
        self.assertEqual(result["export"]["status"], "failed")
        self.assertEqual(result["export"]["errno"], errno.EEXIST)
        self.assertEqual(fingerprint(destination), before)
        self.assertEqual(Path(result["export"]["temporaryPath"]).read_bytes(), self.body)

    def test_same_path_is_rejected_before_read(self):
        with mock.patch.object(reader, "read_note", side_effect=AssertionError("Source must not be read")):
            result, code = reader.inspect_and_export(self.source, self.source)
        self.observation["result"] = result
        self.assertEqual(code, 1)
        self.assertEqual(result["state"], "not_read")
        self.assertEqual(result["export"]["status"], "refused")

    def test_var_private_var_alias_is_rejected_before_read(self):
        self.assertTrue(str(self.source).startswith("/private/var/"))
        alias = Path(str(self.source).removeprefix("/private"))
        with mock.patch.object(reader, "read_note", side_effect=AssertionError("Source must not be read")):
            result, code = reader.inspect_and_export(self.source, alias)
        self.observation.update(alias=str(alias), result=result)
        self.assertEqual(code, 1)
        self.assertEqual(result["state"], "not_read")
        cli_result, cli_code = self.cli(self.source, alias)
        self.assertEqual(cli_code, 1)
        self.assertEqual(cli_result["export"]["status"], "refused")

    def test_symlink_alias_is_rejected_before_read(self):
        alias = self.directory / "alias.png"
        alias.symlink_to(self.source)
        with mock.patch.object(reader, "read_note", side_effect=AssertionError("Source must not be read")):
            result, code = reader.inspect_and_export(self.source, alias)
        self.observation["result"] = result
        self.assertEqual(code, 1)
        self.assertTrue(alias.is_symlink())
        self.assertEqual(result["state"], "not_read")

    def test_deleted_after_publication_is_unconfirmed(self):
        destination = self.directory / "deleted.md"
        publish = reader.publish_exclusive

        def delete_after_publish(temporary, target):
            publish(temporary, target)
            Path(target).unlink()  # Deliberate race injection on this test's file.

        with mock.patch.object(reader, "publish_exclusive", side_effect=delete_after_publish):
            result = reader.export_new_file(destination, self.body)
        self.observation["result"] = result
        self.assertEqual(result["status"], "publication_unconfirmed")
        self.assertFalse(destination.exists())
        self.assertEqual(Path(result["evidencePath"]).read_bytes(), self.body)

    def test_replaced_after_publication_is_unconfirmed(self):
        destination = self.directory / "replaced.md"
        publish = reader.publish_exclusive
        replacement = b"concurrent replacement must remain\n"

        def replace_after_publish(temporary, target):
            publish(temporary, target)
            Path(target).unlink()  # Deliberate race injection on this test's file.
            Path(target).write_bytes(replacement)

        with mock.patch.object(reader, "publish_exclusive", side_effect=replace_after_publish):
            result = reader.export_new_file(destination, self.body)
        self.observation["result"] = result
        self.assertEqual(result["status"], "publication_unconfirmed")
        self.assertEqual(destination.read_bytes(), replacement)
        self.assertEqual(Path(result["evidencePath"]).read_bytes(), self.body)

    def test_partial_writes_are_completed(self):
        destination = self.directory / "partial.md"
        write = os.write
        with mock.patch.object(reader.os, "write", side_effect=lambda fd, data: write(fd, data[:3])):
            result = reader.export_new_file(destination, self.body)
        self.observation["result"] = result
        self.assertEqual(result["status"], "created")
        self.assertEqual(destination.read_bytes(), self.body)

    def test_write_failure_retains_temporary_and_never_publishes(self):
        destination = self.directory / "failed.md"
        with mock.patch.object(reader.os, "write", side_effect=OSError(errno.ENOSPC, "injected disk full")):
            result = reader.export_new_file(destination, self.body)
        self.observation["result"] = result
        self.assertEqual(result["status"], "failed")
        self.assertFalse(result["publicationAttemptCompleted"])
        self.assertFalse(destination.exists())
        self.assertTrue(Path(result["temporaryPath"]).exists())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(ExportRegression)
    result = unittest.TextTestRunner(stream=sys.stdout, verbosity=2).run(suite)
    report = {"schema": "findernotes-fn08-independent-read-final-v1",
              "recordedUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "root": str(ExportRegression.root), "status": "passed" if result.wasSuccessful() else "failed",
              "testsRun": result.testsRun, "failures": len(result.failures), "errors": len(result.errors),
              "argv": sys.argv, "helperSHA256": hashlib.sha256(Path(reader.__file__).read_bytes()).hexdigest(),
              "testsSHA256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              "allSyntheticSourcesUnchanged": all(item["sourceUnchanged"] for item in ExportRegression.observations),
              "observations": ExportRegression.observations,
              "limitations": ["Race/failure cases are deterministic helper-level injections, not product UI tests.",
                              "Path identity and bytes are confirmed at the observed check, not protected from later mutation.",
                              "All test files are new synthetic copies; no historical or UI fixtures were changed.",
                              "Failed temporary and diagnostic files are retained; no concurrent replacement is deleted."]}
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    (ExportRegression.root / "independent-read-final.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print("Evidence root:", ExportRegression.root)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())
