#!/usr/bin/env python3
"""Install the local trial without replacing any existing destination."""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile


def manifest(root):
    result = {}
    for path in sorted(root.rglob('*')):
        relative = str(path.relative_to(root))
        if path.is_symlink():
            raise ValueError(f'Unexpected symlink in local trial: {relative}')
        if path.is_file():
            result[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
    return result


def validate(root):
    if root.is_symlink() or not root.is_dir():
        raise ValueError('Source must be an ordinary application directory')
    info = plistlib.loads((root / 'Contents/Info.plist').read_bytes())
    if (info.get('CFBundleIdentifier'), info.get('CFBundleShortVersionString'),
            info.get('CFBundleVersion')) != ('com.findernotes.FinderNotes.LocalTrial', '0.1.0', '11'):
        raise ValueError('Expected LocalTrial identity, version 0.1.0, build 11')
    if (info.get('CFBundleName'), info.get('CFBundleDisplayName')) != ('FinderNotes', 'FinderNotes'):
        raise ValueError('Expected FinderNotes application name and display name')
    services = info.get('NSServices', [])
    if len(services) != 1 or services[0].get('NSMenuItem', {}).get('default') != '用 FinderNotes 编辑笔记':
        raise ValueError('Unexpected Finder service')
    if services[0].get('NSPortName') != 'FinderNotesLocalTrial':
        raise ValueError('Unexpected service port')
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(root)], check=True)
    return info, manifest(root)


def install(source, destination):
    source = source.expanduser().absolute()
    destination = destination.expanduser().absolute()
    if os.path.lexists(destination):
        raise FileExistsError(f'Refusing to replace existing destination: {destination}')
    info, original = validate(source)
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.parent.is_symlink():
        raise ValueError('Destination parent must not be a symlink')
    stage_root = Path(tempfile.mkdtemp(prefix='.findernotes-install-', dir=destination.parent))
    staged = stage_root / destination.name
    try:
        subprocess.run(['/usr/bin/ditto', str(source), str(staged)], check=True)
        _, copied = validate(staged)
        if original != copied or original != manifest(source):
            raise ValueError('Source changed or copied application bytes differ')
        libc = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
        libc.renamex_np.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        libc.renamex_np.restype = ctypes.c_int
        # RENAME_EXCL makes destination publication refuse a concurrent collision.
        if libc.renamex_np(os.fsencode(staged), os.fsencode(destination), 0x00000004) != 0:
            code = ctypes.get_errno()
            raise OSError(code, os.strerror(code), str(destination))
        _, installed = validate(destination)
        if installed != original:
            raise ValueError('Installed bytes differ; preserve destination for inspection')
        return {'status': 'installed', 'source': str(source), 'destination': str(destination),
                'bundleID': info['CFBundleIdentifier'], 'version': info['CFBundleShortVersionString'],
                'build': info['CFBundleVersion'], 'filesSHA256': installed,
                'recoveryMigration': False, 'settingsChanged': False}
    finally:
        # Only this invocation's unique staging directory is removed, never destination.
        if stage_root.exists():
            shutil.rmtree(stage_root)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    project = Path(__file__).resolve().parent.parent
    parser.add_argument('--source', type=Path, default=project / '.build/DerivedData-build11/Build/Products/Release/FinderNotes.app')
    parser.add_argument('--destination', type=Path, default=Path.home() / 'Applications/FinderNotes.app')
    args = parser.parse_args()
    try:
        print(json.dumps(install(args.source, args.destination), ensure_ascii=False, indent=2))
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(json.dumps({'status': 'failed', 'error': str(error)}, ensure_ascii=False))
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
