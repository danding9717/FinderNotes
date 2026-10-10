"""Isolated filesystem tests; signature/process hooks do not claim real-app validation."""
import base64
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

SCRIPTS = Path(__file__).resolve().parents[1] / 'scripts'
sys.path.insert(0, str(SCRIPTS))
import install_local_trial as installer
import prepare_update as preparation


def fake_signature(_):
    pass


def fake_app(path, *, build='12', bundle_id=installer.BUNDLE_ID):
    (path / 'Contents/MacOS').mkdir(parents=True)
    info = {'CFBundleIdentifier': bundle_id, 'CFBundleShortVersionString': '0.1.1',
            'CFBundleVersion': build, 'CFBundleExecutable': 'FinderNotes',
            'CFBundleName': 'FinderNotes', 'CFBundleDisplayName': 'FinderNotes',
            'LSMinimumSystemVersion': '26.0', 'SUPublicEDKey': base64.b64encode(bytes(32)).decode(),
            'SUFeedURL': preparation.FEED_URL, 'SUVerifyUpdateBeforeExtraction': True,
            'NSServices': [{'NSMenuItem': {'default': '用 FinderNotes 编辑笔记'},
                            'NSPortName': 'FinderNotesLocalTrial', 'NSMessage': 'receiveFiles'}]}
    (path / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    executable = path / 'Contents/MacOS/FinderNotes'
    executable.write_bytes(b'fixture-build-' + build.encode())
    executable.chmod(0o755)
    return path


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='findernotes-tools-test-')
        self.root = Path(self.temporary.name).resolve()
        self.source = fake_app(self.root / 'source/FinderNotes.app')
        self.destination = self.root / 'Applications/FinderNotes.app'

    def tearDown(self):
        self.temporary.cleanup()

    def install(self, **kwargs):
        return installer.install(self.source, self.destination, signature_verifier=fake_signature,
                                 process_inspector=lambda: [], **kwargs)

    def old_app(self, **kwargs):
        return fake_app(self.destination, build='11', **kwargs)

    def test_first_install_verifies_and_keeps_source(self):
        before = installer.manifest(self.source)
        result = self.install()
        self.assertEqual(result['status'], 'installed')
        self.assertEqual(before, installer.manifest(self.destination))
        self.assertEqual(before, installer.manifest(self.source))
        self.assertFalse(result['replacedExisting'])
        self.assertEqual(list(self.destination.parent.glob('.findernotes-install-*')), [])

    def test_existing_destination_requires_explicit_flag(self):
        self.old_app()
        before = installer.manifest(self.destination)
        with self.assertRaises(FileExistsError):
            self.install()
        self.assertEqual(before, installer.manifest(self.destination))

    def test_explicit_upgrade_deletes_old_app_and_preserves_unrelated_data(self):
        self.old_app()
        recovery = self.root / 'DraftRecovery/v1/private.json'
        recovery.parent.mkdir(parents=True)
        recovery.write_bytes(b'draft-do-not-touch')
        result = self.install(replace_existing=True)
        self.assertTrue(result['replacedExisting'])
        self.assertTrue(result['oldApplicationDeleted'])
        self.assertEqual(recovery.read_bytes(), b'draft-do-not-touch')
        self.assertEqual(list(self.destination.parent.glob('.findernotes-install-*')), [])

    def test_wrong_destination_identity_preserved(self):
        self.old_app(bundle_id='com.other.application')
        before = installer.manifest(self.destination)
        with self.assertRaises(installer.InstallFailure):
            self.install(replace_existing=True)
        self.assertEqual(before, installer.manifest(self.destination))

    def test_downgrade_refused(self):
        fake_app(self.destination, build='13')
        with self.assertRaises(installer.InstallFailure):
            self.install(replace_existing=True)
        self.assertEqual(plistlib.loads((self.destination / 'Contents/Info.plist').read_bytes())['CFBundleVersion'], '13')

    def test_signature_failure_prevents_publication(self):
        def invalid(_):
            raise ValueError('invalid signature')
        with self.assertRaises(ValueError):
            installer.install(self.source, self.destination, signature_verifier=invalid,
                              process_inspector=lambda: [])
        self.assertFalse(self.destination.exists())

    def test_running_app_refused_without_killing(self):
        with self.assertRaisesRegex(ValueError, 'Quit FinderNotes'):
            installer.install(self.source, self.destination, signature_verifier=fake_signature,
                              process_inspector=lambda: [{'pid': '999', 'application': 'fixture'}])
        self.assertFalse(self.destination.exists())

    def test_source_symlink_refused(self):
        link = self.root / 'alias.app'
        link.symlink_to(self.source, target_is_directory=True)
        with self.assertRaises(ValueError):
            installer.install(link, self.destination, signature_verifier=fake_signature,
                              process_inspector=lambda: [])

    def test_destination_parent_symlink_refused(self):
        directory = self.root / 'real-apps'
        directory.mkdir()
        self.destination.parent.symlink_to(directory, target_is_directory=True)
        with self.assertRaises(ValueError):
            self.install()
        self.assertEqual(list(directory.iterdir()), [])

    def test_internal_framework_symlink_preserved(self):
        directory = self.source / 'Contents/Frameworks/Fixture.framework'
        (directory / 'Versions/A').mkdir(parents=True)
        (directory / 'Versions/A/Fixture').write_bytes(b'framework')
        (directory / 'Versions/Current').symlink_to('A')
        (directory / 'Fixture').symlink_to('Versions/Current/Fixture')
        self.install()
        self.assertTrue((self.destination / 'Contents/Frameworks/Fixture.framework/Fixture').is_symlink())

    def test_escaping_symlink_refused(self):
        (self.source / 'Contents/outside').symlink_to('../../../outside')
        (self.root / 'outside').write_bytes(b'private')
        with self.assertRaises(ValueError):
            self.install()
        self.assertFalse(self.destination.exists())

    def test_source_mutation_after_copy_preserves_evidence(self):
        def mutating_copy(source, staged):
            installer.copy_app(source, staged)
            (source / 'Contents/MacOS/FinderNotes').write_bytes(b'changed')
        with self.assertRaises(installer.InstallFailure) as failure:
            self.install(copier=mutating_copy)
        self.assertTrue(Path(failure.exception.evidence['stagingDirectory']).exists())
        self.assertFalse(self.destination.exists())

    def test_concurrent_lock_refused(self):
        self.destination.parent.mkdir()
        lock = self.destination.parent / '.FinderNotes.app.install.lock'
        lock.write_bytes(b'other installer')
        with self.assertRaises(FileExistsError):
            self.install()
        self.assertEqual(lock.read_bytes(), b'other installer')

    def test_destination_appearing_during_source_validation_never_replaced(self):
        def appearing_destination(path):
            if path == self.source and not self.destination.exists():
                self.old_app()
        with self.assertRaises(installer.InstallFailure):
            installer.install(self.source, self.destination, signature_verifier=appearing_destination,
                              process_inspector=lambda: [])
        self.assertEqual(plistlib.loads((self.destination / 'Contents/Info.plist').read_bytes())['CFBundleVersion'], '11')

    def test_concurrent_first_install_collision_preserved(self):
        def colliding_copy(source, staged):
            installer.copy_app(source, staged)
            self.destination.mkdir()
            (self.destination / 'other').write_bytes(b'concurrent')
        with self.assertRaises(installer.InstallFailure):
            self.install(copier=colliding_copy)
        self.assertEqual((self.destination / 'other').read_bytes(), b'concurrent')

    def test_concurrent_destination_change_before_upgrade_refused(self):
        self.old_app()
        def mutating_copy(source, staged):
            installer.copy_app(source, staged)
            (self.destination / 'Contents/MacOS/FinderNotes').write_bytes(b'concurrent')
        with self.assertRaises(installer.InstallFailure):
            self.install(replace_existing=True, copier=mutating_copy)
        self.assertEqual((self.destination / 'Contents/MacOS/FinderNotes').read_bytes(), b'concurrent')

    def test_publication_collision_keeps_previous_app_and_other_object(self):
        self.old_app()
        def colliding_publish(source, destination):
            if destination == self.destination:
                destination.mkdir()
                (destination / 'other').write_bytes(b'concurrent')
            installer.rename_exclusive(source, destination)
        with self.assertRaises(installer.InstallFailure) as failure:
            self.install(replace_existing=True, publisher=colliding_publish)
        self.assertEqual((self.destination / 'other').read_bytes(), b'concurrent')
        previous = Path(failure.exception.evidence['previousApplication'])
        self.assertEqual(plistlib.loads((previous / 'Contents/Info.plist').read_bytes())['CFBundleVersion'], '11')

    def test_post_publication_verification_failure_keeps_previous_app(self):
        self.old_app()
        def fail_publication(path):
            if path == self.destination and plistlib.loads((path / 'Contents/Info.plist').read_bytes())['CFBundleVersion'] == '12':
                raise ValueError('published signature verification failed')
        with self.assertRaises(installer.InstallFailure) as failure:
            installer.install(self.source, self.destination, replace_existing=True,
                              signature_verifier=fail_publication, process_inspector=lambda: [])
        self.assertTrue(Path(failure.exception.evidence['previousApplication']).exists())
        self.assertTrue(self.destination.exists())

    def test_cleanup_failure_reports_failure_and_keeps_both_apps(self):
        self.old_app()
        def denied(_):
            raise PermissionError('fixture cleanup denied')
        with self.assertRaises(installer.InstallFailure) as failure:
            self.install(replace_existing=True, remover=denied)
        self.assertTrue(Path(failure.exception.evidence['previousApplication']).exists())
        self.assertTrue(self.destination.exists())


    def test_lock_cleanup_failure_keeps_primary_error_and_previous_app_paths(self):
        self.old_app()
        original_unlink = Path.unlink
        def denied_lock(path, *args, **kwargs):
            if path.name == '.FinderNotes.app.install.lock':
                raise PermissionError('fixture lock cleanup denied')
            return original_unlink(path, *args, **kwargs)
        def denied_old_cleanup(_):
            raise PermissionError('fixture old application cleanup denied')
        with patch.object(Path, 'unlink', denied_lock):
            with self.assertRaises(installer.InstallFailure) as failure:
                self.install(replace_existing=True, remover=denied_old_cleanup)
        self.assertEqual(str(failure.exception), 'fixture old application cleanup denied')
        evidence = failure.exception.evidence
        self.assertIn('fixture lock cleanup denied', evidence['lockCleanupError'])
        self.assertTrue(Path(evidence['previousApplication']).exists())
        self.assertTrue(Path(evidence['stagingDirectory']).exists())
        self.assertTrue(Path(evidence['lockPath']).exists())
        self.assertTrue(evidence['installationVerified'])
        self.assertFalse(evidence['oldApplicationDeleted'])

    def test_successful_upgrade_with_lock_cleanup_failure_is_incomplete(self):
        self.old_app()
        original_unlink = Path.unlink
        def denied_lock(path, *args, **kwargs):
            if path.name == '.FinderNotes.app.install.lock':
                raise PermissionError('fixture lock cleanup denied')
            return original_unlink(path, *args, **kwargs)
        with patch.object(Path, 'unlink', denied_lock):
            with self.assertRaises(installer.InstallFailure) as failure:
                self.install(replace_existing=True)
        evidence = failure.exception.evidence
        self.assertEqual(evidence['status'], 'incomplete')
        self.assertTrue(evidence['installationVerified'])
        self.assertTrue(evidence['oldApplicationDeleted'])
        self.assertTrue(self.destination.exists())
        self.assertTrue(Path(evidence['lockPath']).exists())
        self.assertFalse(Path(evidence['previousApplication']).exists())



class PreparationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='findernotes-package-test-')
        self.root = Path(self.temporary.name).resolve()
        self.source = fake_app(self.root / 'source/FinderNotes.app')
        self.output = self.root / 'review-materials'
        self.signer = self.root / 'fake-sign-update'
        self.signature = base64.b64encode(bytes(64)).decode()
        self.signer.write_text('#!/bin/sh\nprintf "%s\\n" "' + self.signature + '"\n')
        self.signer.chmod(0o755)

    def tearDown(self):
        self.temporary.cleanup()

    def prepare(self, **kwargs):
        return preparation.prepare(self.source, self.output, self.signer,
            validator=lambda path: installer.validate(path, signature_verifier=fake_signature),
            signature_validator=lambda archive, signature, public: None, **kwargs)

    def test_local_archive_roundtrip_and_fixed_https_feed(self):
        result = self.prepare(notes='新增中文说明。\n包含 <需要转义> 的文字。')
        self.assertFalse(result['published'])
        self.assertEqual(result['releaseTag'], 'v0.1.1-12')
        feed = ET.parse(self.output / 'appcast.xml')
        item = feed.find('./channel/item')
        self.assertEqual(item.find('{%s}version' % preparation.SPARKLE).text, '12')
        self.assertEqual(item.find('enclosure').attrib['{%s}edSignature' % preparation.SPARKLE], self.signature)
        self.assertIn('/releases/download/v0.1.1-12/', item.find('enclosure').attrib['url'])
        self.assertIn('&lt;需要转义&gt;', (self.output / 'FinderNotes-0.1.1-12.html').read_text())
        self.assertFalse((self.output / 'verification').exists())
        self.assertEqual(result['archiveLength'], (self.output / 'FinderNotes-0.1.1-12.zip').stat().st_size)

    def test_existing_output_not_overwritten(self):
        self.output.mkdir()
        (self.output / 'keep').write_bytes(b'existing')
        with self.assertRaises(FileExistsError):
            self.prepare()
        self.assertEqual((self.output / 'keep').read_bytes(), b'existing')

    def test_insecure_download_url_refused(self):
        with self.assertRaises(ValueError):
            self.prepare(release_base_url='http://example.test/release/v1')
        self.assertFalse(self.output.exists())

    def test_wrong_feed_refused(self):
        info_path = self.source / 'Contents/Info.plist'
        info = plistlib.loads(info_path.read_bytes())
        info['SUFeedURL'] = 'https://example.test/unapproved.xml'
        info_path.write_bytes(plistlib.dumps(info))
        with self.assertRaises(ValueError):
            self.prepare()

    def test_signature_mismatch_preserves_materials_and_prevents_ready_output(self):
        def invalid(*_):
            raise ValueError('signature does not match embedded public key')
        with self.assertRaises(preparation.PreparationFailure) as failure:
            preparation.prepare(self.source, self.output, self.signer,
                validator=lambda path: installer.validate(path, signature_verifier=fake_signature),
                signature_validator=invalid)
        self.assertFalse(self.output.exists())
        self.assertTrue(Path(failure.exception.evidence).exists())

    def test_invalid_signer_output_refused(self):
        self.signer.write_text('#!/bin/sh\necho wrong-signature\n')
        with self.assertRaises(preparation.PreparationFailure):
            self.prepare()
        self.assertFalse(self.output.exists())

    def test_framework_symlinks_survive_real_ditto_archive(self):
        directory = self.source / 'Contents/Frameworks/Fixture.framework'
        (directory / 'Versions/A').mkdir(parents=True)
        (directory / 'Versions/A/Fixture').write_bytes(b'framework')
        (directory / 'Versions/Current').symlink_to('A')
        (directory / 'Fixture').symlink_to('Versions/Current/Fixture')
        self.prepare()
        extracted = self.root / 'inspection'
        subprocess.run(['/usr/bin/ditto', '-x', '-k', str(self.output / 'FinderNotes-0.1.1-12.zip'), str(extracted)], check=True)
        self.assertTrue((extracted / 'FinderNotes.app/Contents/Frameworks/Fixture.framework/Fixture').is_symlink())


if __name__ == '__main__':
    unittest.main()
