#!/usr/bin/env python3
"""Install a verified LocalTrial app; replacement requires --replace-existing."""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import tempfile

BUNDLE_ID = 'com.findernotes.FinderNotes.LocalTrial'


def ordinary_path(path):
    """Reject symlink ancestors rather than accidentally installing through an alias."""
    for component in (path, *path.parents):
        if component.is_symlink():
            raise ValueError(f'Path must not contain symlinks: {component}')


def identity(path):
    value = path.lstat()
    return value.st_dev, value.st_ino


def manifest(root):
    result = {}
    resolved_root = root.resolve(strict=True)
    for path in sorted(root.rglob('*')):
        relative = str(path.relative_to(root))
        mode = path.lstat().st_mode
        if stat.S_ISLNK(mode):
            # Sparkle.framework contains ordinary versioned-framework links.
            # Absolute, dangling, and escaping links are never accepted.
            target = os.readlink(path)
            try:
                internal = path.resolve(strict=True).is_relative_to(resolved_root)
            except (OSError, RuntimeError) as error:
                raise ValueError(f'Invalid application symlink: {relative}') from error
            if os.path.isabs(target) or not internal:
                raise ValueError(f'Unsafe application symlink: {relative}')
            result[relative] = {'symlink': target}
        elif stat.S_ISREG(mode):
            result[relative] = {'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
                                'mode': stat.S_IMODE(mode)}
        elif stat.S_ISDIR(mode):
            result[relative] = {'directory': True, 'mode': stat.S_IMODE(mode)}
        else:
            raise ValueError(f'Unexpected application object: {relative}')
    return result


def verify_signature(root):
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(root)], check=True)


def validate(root, *, signature_verifier=verify_signature):
    if root.is_symlink() or not root.is_dir():
        raise ValueError('Expected an ordinary application directory')
    info = plistlib.loads((root / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != BUNDLE_ID:
        raise ValueError(f'Expected LocalTrial identity {BUNDLE_ID}')
    if not re.fullmatch(r'[0-9]+(?:\.[0-9]+){1,2}', str(info.get('CFBundleShortVersionString', ''))):
        raise ValueError('Expected a numeric application version')
    if not re.fullmatch(r'[1-9][0-9]*', str(info.get('CFBundleVersion', ''))):
        raise ValueError('Expected a positive integer build number')
    if (info.get('CFBundleName'), info.get('CFBundleDisplayName')) != ('FinderNotes', 'FinderNotes'):
        raise ValueError('Expected FinderNotes application name and display name')
    if info.get('CFBundleExecutable') != 'FinderNotes':
        raise ValueError('Expected FinderNotes executable')
    services = info.get('NSServices', [])
    if (not isinstance(services, list) or len(services) != 1
            or not isinstance(services[0], dict)
            or services[0].get('NSMenuItem') != {'default': '用 FinderNotes 编辑笔记'}
            or services[0].get('NSPortName') != 'FinderNotesLocalTrial'
            or services[0].get('NSMessage') != 'receiveFiles'):
        raise ValueError('Unexpected Finder service identity')
    contents = manifest(root)
    signature_verifier(root)
    return info, contents


def running_local_trials():
    """Inspect executable paths; never kill a process or ask the app to discard drafts."""
    output = subprocess.run(['/bin/ps', 'axww', '-o', 'pid=', '-o', 'comm='],
                            capture_output=True, text=True, check=True).stdout
    result = []
    for line in output.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) != 2:
            continue
        executable = Path(fields[1])
        if executable.name != 'FinderNotes' or executable.parent.name != 'MacOS':
            continue
        app = executable.parent.parent.parent
        try:
            info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
            if info.get('CFBundleIdentifier') == BUNDLE_ID:
                result.append({'pid': fields[0], 'application': str(app)})
        except (OSError, ValueError):
            # An unreadable FinderNotes process is still an unsafe installation target.
            result.append({'pid': fields[0], 'application': str(app), 'identity': 'unreadable'})
    return result


def ensure_not_running(process_inspector):
    processes = process_inspector()
    if processes:
        raise ValueError('Quit FinderNotes normally before installing; running processes: '
                         + json.dumps(processes, ensure_ascii=False))


def copy_app(source, destination):
    subprocess.run(['/usr/bin/ditto', str(source), str(destination)], check=True)


def rename_exclusive(source, destination):
    libc = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
    libc.renamex_np.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    libc.renamex_np.restype = ctypes.c_int
    # RENAME_EXCL refuses a destination that appears concurrently.
    if libc.renamex_np(os.fsencode(source), os.fsencode(destination), 0x00000004) != 0:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code), str(destination))


class InstallFailure(RuntimeError):
    def __init__(self, message, evidence):
        super().__init__(message)
        self.evidence = evidence


def install(source, destination, *, replace_existing=False,
            signature_verifier=verify_signature, process_inspector=running_local_trials,
            copier=copy_app, publisher=rename_exclusive, remover=shutil.rmtree):
    source = source.expanduser().absolute()
    destination = destination.expanduser().absolute()
    ordinary_path(source)
    ordinary_path(destination)
    if source == destination or source.is_relative_to(destination) or destination.is_relative_to(source):
        raise ValueError('Source and destination must be independent application paths')
    if os.path.lexists(destination) and not replace_existing:
        raise FileExistsError(f'Refusing to replace existing destination: {destination}; use --replace-existing explicitly')
    info, original = validate(source, signature_verifier=signature_verifier)
    source_identity = identity(source)
    ensure_not_running(process_inspector)
    destination.parent.mkdir(parents=True, exist_ok=True)
    ordinary_path(destination.parent)
    parent_identity = identity(destination.parent)
    lock = destination.parent / ('.' + destination.name + '.install.lock')
    lock_fd = os.open(lock, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    lock_identity = identity(lock)
    stage_root = None
    previous = None
    operation_failure = None
    installation_verified = False
    old_application_deleted = False
    try:
        old_manifest = old_identity = None
        if os.path.lexists(destination):
            if not replace_existing:
                raise FileExistsError(f'Destination appeared concurrently: {destination}')
            old_info, old_manifest = validate(destination, signature_verifier=signature_verifier)
            old_identity = identity(destination)
            if int(info['CFBundleVersion']) <= int(old_info['CFBundleVersion']):
                raise ValueError('Replacement build must be newer than the installed build')
        stage_root = Path(tempfile.mkdtemp(prefix='.findernotes-install-', dir=destination.parent))
        stage_identity = identity(stage_root)
        staged = stage_root / destination.name
        copier(source, staged)
        _, copied = validate(staged, signature_verifier=signature_verifier)
        if original != copied or original != manifest(source) or identity(source) != source_identity:
            raise ValueError('Source changed or copied application differs')
        ordinary_path(destination.parent)
        if identity(destination.parent) != parent_identity or identity(stage_root) != stage_identity:
            raise ValueError('Installation directory changed concurrently')
        ensure_not_running(process_inspector)
        if old_identity is not None:
            if identity(destination) != old_identity or manifest(destination) != old_manifest:
                raise ValueError('Existing application changed concurrently')
            previous = stage_root / 'previous.app'
            publisher(destination, previous)
            if identity(previous) != old_identity or manifest(previous) != old_manifest:
                raise ValueError('Previous application changed during staging; preserve it for inspection')
        staged_identity = identity(staged)
        publisher(staged, destination)
        _, installed = validate(destination, signature_verifier=signature_verifier)
        if installed != original or identity(destination) != staged_identity:
            raise ValueError('Installed application differs; preserve both applications for inspection')
        if identity(source) != source_identity or manifest(source) != original:
            raise ValueError('Source changed before installation verification finished')
        ensure_not_running(process_inspector)
        installation_verified = True
        if previous is not None:
            if identity(previous) != old_identity or manifest(previous) != old_manifest:
                raise ValueError('Previous application changed; refuse to delete it')
            # Direct deletion only after publication and verification. No Trash or recovery cleanup.
            remover(previous)
            if os.path.lexists(previous):
                raise ValueError('Previous application cleanup did not finish')
            old_application_deleted = True
        stage_root.rmdir()
        return {'status': 'installed', 'source': str(source), 'destination': str(destination),
                'bundleID': info['CFBundleIdentifier'], 'version': info['CFBundleShortVersionString'],
                'build': info['CFBundleVersion'], 'filesSHA256': installed,
                'replacedExisting': old_identity is not None, 'oldApplicationDeleted': old_application_deleted,
                'recoveryMigration': False, 'settingsChanged': False}
    except Exception as error:
        evidence = {'destination': str(destination), 'stagingDirectory': str(stage_root) if stage_root else None,
                    'previousApplication': str(previous) if previous else None,
                    'recoveryModified': False}
        evidence.update({'installationVerified': installation_verified,
                         'oldApplicationDeleted': old_application_deleted})
        operation_failure = InstallFailure(str(error), evidence)
        raise operation_failure from error
    finally:
        try:
            os.close(lock_fd)
            if os.path.lexists(lock) and identity(lock) == lock_identity:
                lock.unlink()
        except OSError as cleanup_error:
            cleanup_evidence = {'lockPath': str(lock), 'lockCleanupError': str(cleanup_error)}
            if operation_failure is not None:
                # Preserve the primary exception and its recovery paths.
                operation_failure.evidence.update(cleanup_evidence)
            else:
                cleanup_evidence.update({'status': 'incomplete', 'destination': str(destination),
                    'stagingDirectory': str(stage_root) if stage_root else None,
                    'previousApplication': str(previous) if previous else None,
                    'installationVerified': installation_verified,
                    'oldApplicationDeleted': old_application_deleted, 'recoveryModified': False})
                raise InstallFailure('Application installation finished, but installer lock cleanup failed',
                                     cleanup_evidence) from cleanup_error


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    project = Path(__file__).resolve().parent.parent
    parser.add_argument('--source', type=Path, default=project / '.build/DerivedData-build12/Build/Products/Release/FinderNotes.app')
    parser.add_argument('--destination', type=Path, default=Path.home() / 'Applications/FinderNotes.app')
    parser.add_argument('--replace-existing', action='store_true', help='Explicitly replace an older, verified LocalTrial app after normal quit')
    args = parser.parse_args()
    try:
        print(json.dumps(install(args.source, args.destination, replace_existing=args.replace_existing), ensure_ascii=False, indent=2))
    except (OSError, ValueError, subprocess.CalledProcessError, InstallFailure) as error:
        result = {'status': 'failed', 'error': str(error)}
        if isinstance(error, InstallFailure):
            result.update(error.evidence)
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
