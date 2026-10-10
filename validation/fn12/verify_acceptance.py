#!/usr/bin/env python3
"""Read-only FN12 acceptance verification; writes only its own evidence files.

--baseline explicitly saves the build-12 media/PID baseline once.
Default verification expects build 13; --expect-build 12 is a preflight only.
--watch-cleanup observes one strictly bound receipt path, never repairs/deletes it.
"""
import argparse
from datetime import datetime, timezone
import errno
import hashlib
import json
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import time
import uuid

PROJECT = Path(__file__).resolve().parents[2]
ROOT = PROJECT / '.build/FN12Acceptance'
BUNDLE_ID = 'com.findernotes.FinderNotes.FN12Acceptance'
APP_NAME = 'FinderNotes 更新验收.app'
APP = ROOT / 'Installed' / APP_NAME
MEDIA = ROOT / 'media'
EVIDENCE = ROOT / 'evidence'
BASELINE = EVIDENCE / 'media-baseline.json'
RECEIPTS = Path.home() / 'Library/Application Support' / BUNDLE_ID / 'UpdateResults'
CACHE = Path.home() / 'Library/Caches' / BUNDLE_ID / 'org.sparkle-project.Sparkle/Installation'
NOTE = 'com.findernotes.note.v1'
STATES = {'completed', 'incomplete', 'unknown'}


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def ordinary_path(path):
    for component in (path, *path.parents):
        if component.is_symlink():
            raise ValueError('Refusing symlink path: ' + str(component))


def file_identity(value):
    return {'device': value.st_dev, 'inode': value.st_ino}


def read_regular(path, limit=65536):
    ordinary_path(path)
    before = path.lstat()
    if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or before.st_uid != os.geteuid() or before.st_size > limit:
        raise ValueError('Expected an owned, single-link, bounded ordinary file: ' + str(path))
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        held = os.fstat(descriptor)
        if file_identity(held) != file_identity(before) or not stat.S_ISREG(held.st_mode):
            raise ValueError('File identity changed before reading')
        data = bytearray()
        while len(data) <= limit:
            chunk = os.read(descriptor, min(65536, limit + 1 - len(data)))
            if not chunk:
                break
            data.extend(chunk)
        after, named = os.fstat(descriptor), path.lstat()
        ordinary_path(path)
        if (len(data) > limit or len(data) != held.st_size or file_identity(named) != file_identity(held)
                or after.st_nlink != 1 or after.st_size != held.st_size
                or after.st_mtime_ns != held.st_mtime_ns or after.st_ctime_ns != held.st_ctime_ns):
            raise ValueError('File changed during bounded reading')
        return bytes(data)
    finally:
        os.close(descriptor)


def read_json(path):
    return json.loads(read_regular(path).decode('utf-8'))


def write_evidence(path, value):
    if path.parent != EVIDENCE:
        raise ValueError('Evidence must stay in the fixed acceptance evidence directory')
    ordinary_path(ROOT)
    if not ROOT.is_dir():
        raise ValueError('Acceptance fixtures have not been prepared')
    EVIDENCE.mkdir(mode=0o700, exist_ok=True)
    ordinary_path(EVIDENCE)
    if EVIDENCE.stat().st_uid != os.geteuid():
        raise ValueError('Evidence directory is not owned by the current user')
    data = (json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode('utf-8')
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        offset = 0
        while offset < len(data):
            written = os.write(descriptor, data[offset:])
            if written <= 0:
                raise OSError('Evidence write made no progress')
            offset += written
        os.fsync(descriptor)
        if file_identity(os.fstat(descriptor)) != file_identity(path.lstat()):
            raise ValueError('Evidence path changed during publication')
    finally:
        os.close(descriptor)


def app_snapshot(expected_build):
    result = {'path': str(APP), 'expectedBuild': str(expected_build), 'status': 'unknown', 'pids': []}
    try:
        ordinary_path(APP)
        info = plistlib.loads(read_regular(APP / 'Contents/Info.plist'))
        build = info.get('CFBundleVersion')
        version = info.get('CFBundleShortVersionString')
        if (info.get('CFBundleIdentifier') != BUNDLE_ID or build not in ('12', '13')
                or version != {'12': '0.1.1', '13': '0.1.2'}[build]
                or info.get('CFBundleExecutable') != 'FinderNotes'
                or info.get('SUFeedURL') != 'http://localhost:18777/appcast.xml'):
            raise ValueError('Installed app identity, version, executable, or acceptance feed differs')
        result.update(bundleID=BUNDLE_ID, version=version, build=build, identity=file_identity(APP.lstat()))
        verified = subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(APP)], capture_output=True, text=True)
        result['strictSignatureVerified'] = verified.returncode == 0
        if verified.returncode:
            raise ValueError('Strict codesign verification failed: ' + verified.stderr.strip()[:512])
        processes = subprocess.run(['/bin/ps', 'axww', '-o', 'pid=', '-o', 'comm='], capture_output=True, text=True, check=True)
        executable = str(APP / 'Contents/MacOS/FinderNotes')
        result['pids'] = [int(parts[0]) for line in processes.stdout.splitlines()
                          if len(parts := line.strip().split(None, 1)) == 2 and parts[1] == executable]
        result['processEvidence'] = 'ps exact executable path; compare PID against the explicit baseline'
        result['status'] = 'verified' if build == str(expected_build) and len(result['pids']) == 1 else 'unknown'
        if result['status'] != 'verified':
            result['reason'] = 'Expected build and exactly one running process have not both been confirmed'
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        result['reason'] = str(error)
    return result


def media_snapshot():
    ordinary_path(MEDIA)
    if not MEDIA.is_dir():
        raise ValueError('The fixed acceptance media directory is missing')
    paths = sorted(path for path in MEDIA.iterdir() if path.suffix.lower() == '.png')
    if not paths or len(paths) > 128:
        raise ValueError('Expected 1 to 128 direct synthetic PNG files')
    result = []
    for path in paths:
        item = {'name': path.name, 'path': str(path), 'attribute': NOTE, 'state': 'read_error'}
        descriptor = None
        try:
            ordinary_path(path)
            before = path.lstat()
            if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or before.st_uid != os.geteuid():
                raise ValueError('Expected an owned single-link synthetic PNG')
            descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
            held = os.fstat(descriptor)
            if file_identity(held) != file_identity(before):
                raise ValueError('PNG identity changed before reading')
            digest = hashlib.sha256()
            for chunk in iter(lambda: os.read(descriptor, 65536), b''):
                digest.update(chunk)
            note = subprocess.run(['/usr/bin/xattr', '-px', NOTE, str(path)], capture_output=True,
                                  text=True, env={**os.environ, 'LC_ALL': 'C'})
            if note.returncode == 0:
                data = bytes.fromhex(note.stdout)
                try:
                    data.decode('utf-8')
                    state = 'present' if data else 'empty'
                except UnicodeDecodeError:
                    state = 'invalid_utf8'
                item.update(state=state, byteLength=len(data), sha256=hashlib.sha256(data).hexdigest())
            elif 'No such xattr' in note.stderr:
                item.update(state='missing', byteLength=None, sha256=None)
            else:
                raise ValueError('The owned note attribute could not be read')
            after, named = os.fstat(descriptor), path.lstat()
            ordinary_path(path)
            if (file_identity(named) != file_identity(held) or after.st_size != held.st_size
                    or after.st_mtime_ns != held.st_mtime_ns or after.st_ctime_ns != held.st_ctime_ns):
                raise ValueError('Synthetic PNG or attribute changed during verification')
            item.update(identity=file_identity(held), mediaSHA256=digest.hexdigest(), mediaByteLength=held.st_size)
        except (OSError, ValueError, subprocess.CalledProcessError) as error:
            item.update(state='read_error', reason=str(error))
        finally:
            if descriptor is not None:
                os.close(descriptor)
        result.append(item)
    return result


def receipt_snapshot():
    result = []
    try:
        ordinary_path(RECEIPTS)
        if not RECEIPTS.exists():
            return result
        children = list(RECEIPTS.iterdir())
        if len(children) > 128:
            raise ValueError('Too many acceptance receipts; no directory expansion performed')
        for path in sorted(children):
            if path.suffix != '.json':
                continue
            try:
                record = read_json(path)
                if (record.get('schema') != 1 or record.get('bundleID') != BUNDLE_ID
                        or record.get('installationPath') != str(APP)
                        or path.name != str(uuid.UUID(record['id'])).upper() + '.json'
                        or record.get('evaluation', {}).get('status') not in STATES):
                    raise ValueError('Receipt does not match the fixed acceptance app')
                result.append({'path': str(path), 'record': record})
            except (OSError, ValueError, KeyError, TypeError) as error:
                result.append({'path': str(path), 'readStatus': 'unknown', 'reason': str(error)})
    except (OSError, ValueError) as error:
        result.append({'readStatus': 'unknown', 'reason': str(error)})
    return result


def valid_identity(value):
    return (isinstance(value, dict) and set(value) == {'device', 'inode'}
            and all(isinstance(value[key], int) and not isinstance(value[key], bool) and value[key] >= 0 for key in value)
            and value['inode'] > 0)


def strict_binding(record):
    try:
        binding = record['binding']
        directory, app = Path(binding['directoryPath']), Path(binding['bundlePath'])
        if (record['bundleID'] != BUNDLE_ID or record['installationPath'] != str(APP)
                or record['cacheInstallationPath'] != str(CACHE)
                or record['oldVersion'] != {'display': '0.1.1', 'build': '12'}
                or record['targetVersion'] != {'display': '0.1.2', 'build': '13'}
                or directory.parent != CACHE or app.parent.parent != directory or app.name != APP_NAME
                or str(directory) != os.path.normpath(str(directory)) or str(app) != os.path.normpath(str(app))
                or not all(valid_identity(value) for value in (record['oldIdentity'], binding['directoryIdentity'], binding['extractionIdentity']))):
            return None
        return binding
    except (KeyError, TypeError, ValueError):
        return None


def object_state(path, expected_identity):
    try:
        ordinary_path(path)
        value = path.lstat()
        if not stat.S_ISDIR(value.st_mode):
            return 'differentObject'
        return 'same' if file_identity(value) == expected_identity else 'differentObject'
    except FileNotFoundError:
        return 'missing'
    except (OSError, ValueError):
        return 'unreadable'


def observe(record):
    binding = strict_binding(record)
    if binding is None:
        return 'unreadable'
    directory = Path(binding['directoryPath'])
    app = Path(binding['bundlePath'])
    for path, expected in ((directory, binding['directoryIdentity']), (app.parent, binding['extractionIdentity'])):
        state = object_state(path, expected)
        if state != 'same':
            return state
    state = object_state(app, record['oldIdentity'])
    return 'oldBundlePresent' if state == 'same' else state


def cleanup_evaluation(observations):
    states = [value['state'] for value in observations]
    if states and states[-1] == 'oldBundlePresent':
        return {'status': 'incomplete', 'reason': 'Exact old inode still present at final observation'}
    if 'oldBundlePresent' in states and states[-1] == 'missing':
        last_old = len(states) - 1 - states[::-1].index('oldBundlePresent')
        if all(state in ('oldBundlePresent', 'missing') for state in states[last_old:]):
            return {'status': 'completed', 'reason': 'Exact old inode observed, then its strictly bound path disappeared'}
    return {'status': 'unknown', 'reason': 'Old inode removal was not observed reliably; absence alone is not cleanup proof'}



def watch_candidate(record, receipt_id=None):
    if strict_binding(record) is None:
        return False
    if receipt_id:
        return record.get('id', '').upper() == receipt_id
    if record.get('awaitingRestart') is True:
        return True
    # After Return Editing, watch the already bound cache before the user retries
    # installation. The original app must still be the exact old directory inode.
    return (record.get('awaitingRestart') is False
            and record.get('evaluation', {}).get('reason') == 'termination-cancelled'
            and object_state(APP, record['oldIdentity']) == 'same')


def watch_cleanup(seconds, receipt_id):
    start = time.monotonic()
    record = None
    source = None
    ambiguous = False
    while time.monotonic() - start < seconds:
        candidates = [(entry['path'], entry['record']) for entry in receipt_snapshot()
                      if 'record' in entry and watch_candidate(entry['record'], receipt_id)]
        if len(candidates) == 1:
            source, record = candidates[0]
            break
        if len(candidates) > 1:
            ambiguous = True
            break
        time.sleep(0.05)
    observations = []
    if record:
        previous = None
        while time.monotonic() - start < seconds:
            state = observe(record)
            if state != previous:
                observations.append({'elapsedSeconds': round(time.monotonic() - start, 6), 'state': state})
                previous = state
            if cleanup_evaluation(observations)['status'] == 'completed':
                break
            time.sleep(0.005)
    evaluation = cleanup_evaluation(observations)
    if ambiguous:
        evaluation = {'status': 'unknown', 'reason': 'Multiple active receipts; choose --receipt UUID'}
    elif not record:
        evaluation = {'status': 'unknown', 'reason': 'No strictly bound current receipt appeared within the finite watch'}
    return {'receipt': source, 'receiptID': record.get('id') if record else None,
            'exactBundlePath': record['binding']['bundlePath'] if record else None,
            'oldIdentity': record['oldIdentity'] if record else None,
            'durationSeconds': round(time.monotonic() - start, 6),
            'observations': observations, 'evaluation': evaluation,
            'productReceiptModified': False, 'directoriesSearched': False}


def pid_presence(pid, probe=None):
    """Signal 0 only: permission denial is conservative evidence of a live PID."""
    try:
        (probe or os.kill)(pid, 0)
    except OSError as error:
        if error.errno == errno.ESRCH:
            return 'absent'
        if error.errno == errno.EPERM:
            return 'running'
        return 'unknown'
    return 'running'


def compare_baseline(current, app, pid_probe=None):
    try:
        baseline = read_json(BASELINE)
        if (baseline.get('schema') != 1 or baseline.get('bundleID') != BUNDLE_ID
                or baseline.get('acceptanceRoot') != str(ROOT) or baseline.get('application', {}).get('build') != '12'):
            raise ValueError('Baseline does not match this acceptance run')
        expected = {item['name']: item for item in baseline['media']}
        actual = {item['name']: item for item in current}
        differences = []
        for name in sorted(set(expected) | set(actual)):
            if name not in expected or name not in actual:
                differences.append({'name': name, 'reason': 'Synthetic media file set differs'})
            else:
                fields = ('state', 'byteLength', 'sha256', 'identity', 'mediaSHA256', 'mediaByteLength')
                changed = [field for field in fields if expected[name].get(field) != actual[name].get(field)]
                if changed:
                    differences.append({'name': name, 'changedFields': changed})
        readable = all(item['state'] in ('present', 'empty', 'missing') for item in current)
        prior_pids = baseline['application'].get('pids', [])
        if not isinstance(prior_pids, list) or any(type(pid) is not int or pid <= 0 for pid in prior_pids):
            raise ValueError('Baseline contains an invalid process ID')
        presence = {pid: (pid_probe or pid_presence)(pid) for pid in prior_pids}
        still_running = [pid for pid, state in presence.items() if state == 'running']
        unknown = [pid for pid, state in presence.items() if state not in ('running', 'absent')]
        restarted = (len(app.get('pids', [])) == 1 and bool(prior_pids)
                     and not set(app['pids']) & set(prior_pids)
                     and all(state == 'absent' for state in presence.values()))
        return {'status': 'matches' if not differences and readable else 'differs' if differences else 'unknown',
                'baseline': str(BASELINE), 'differences': differences, 'baselinePIDs': prior_pids,
                'baselinePIDsStillRunning': still_running, 'baselinePIDsPresenceUnknown': unknown,
                'restartedSinceBaseline': restarted}
    except (OSError, ValueError, KeyError, TypeError) as error:
        return {'status': 'unknown', 'baseline': str(BASELINE), 'reason': str(error)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', action='store_true', help='Explicitly save the build-12 media/PID baseline once; never overwrite it')
    parser.add_argument('--expect-build', choices=('12', '13'), help='Default: 12 with --baseline, otherwise 13')
    parser.add_argument('--watch-cleanup', action='store_true', help='Observe only a strictly bound acceptance receipt and exact old inode')
    parser.add_argument('--watch-seconds', type=float, default=60, help='Finite total watch, 1 to 120 seconds (default 60)')
    parser.add_argument('--receipt', help='Exact receipt UUID to disambiguate --watch-cleanup')
    args = parser.parse_args()
    if args.baseline and args.watch_cleanup:
        parser.error('--baseline and --watch-cleanup are separate operations')
    if not 1 <= args.watch_seconds <= 120:
        parser.error('--watch-seconds must be between 1 and 120')
    try:
        receipt_id = str(uuid.UUID(args.receipt)).upper() if args.receipt else None
    except ValueError:
        parser.error('--receipt must be a UUID')
    if args.receipt and not args.watch_cleanup:
        parser.error('--receipt requires --watch-cleanup')
    expected_build = args.expect_build or ('12' if args.baseline else '13')
    result = {'schema': 1, 'checkedAtUTC': utc_now(), 'bundleID': BUNDLE_ID,
              'acceptanceRoot': str(ROOT), 'readOnlyExceptEvidence': True,
              'noteBodyIncluded': False, 'applicationStartedOrStopped': False, 'status': 'unknown',
              'verificationScope': 'installed app/process and synthetic note hashes; cleanup is reported separately'}
    try:
        ordinary_path(ROOT)
        if not ROOT.is_dir():
            raise ValueError('The fixed acceptance fixture directory does not exist')
        if args.watch_cleanup:
            print(json.dumps({'watchStarted': True, 'seconds': args.watch_seconds,
                              'scope': BUNDLE_ID, 'receipt': receipt_id}, ensure_ascii=False), flush=True)
            result['cleanupWatch'] = watch_cleanup(args.watch_seconds, receipt_id)
        result['application'] = app_snapshot(expected_build)
        result['media'] = media_snapshot()
        result['receipts'] = receipt_snapshot()
        if args.baseline:
            if (expected_build != '12' or result['application']['status'] != 'verified'
                    or not all(item['state'] in ('present', 'empty', 'missing') for item in result['media'])):
                raise ValueError('Baseline requires verified running build 12 and readable synthetic note states')
            write_evidence(BASELINE, {**result, 'status': 'baseline_created'})
            result['status'] = 'baseline_created'
            result['baselinePath'] = str(BASELINE)
        else:
            result['mediaComparison'] = compare_baseline(result['media'], result['application'])
            confirmed = result['application']['status'] == 'verified' and result['mediaComparison']['status'] == 'matches'
            if expected_build == '13':
                confirmed = confirmed and result['mediaComparison'].get('restartedSinceBaseline') is True
            if args.watch_cleanup:
                confirmed = confirmed and result['cleanupWatch']['evaluation']['status'] == 'completed'
            result['status'] = 'verified' if confirmed else 'unknown'
            if result.get('cleanupWatch', {}).get('evaluation', {}).get('status') == 'completed' and result['application']['status'] != 'verified':
                result['cleanupWatch']['evaluation'] = {'status': 'unknown', 'reason': 'Exact-path disappearance observed, but target running build was not verified'}
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        result['reason'] = str(error)
    evidence_path = EVIDENCE / (datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S') + '-' + uuid.uuid4().hex[:8] + '-verification.json')
    try:
        write_evidence(evidence_path, result)
        result['evidencePath'] = str(evidence_path)
    except (OSError, ValueError) as error:
        result['evidenceWriteError'] = str(error)
        result['status'] = 'unknown'
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result['status'] in ('verified', 'baseline_created') else 1


if __name__ == '__main__':
    raise SystemExit(main())
