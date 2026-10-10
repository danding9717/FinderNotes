#!/usr/bin/env python3
"""Prepare signed FinderNotes update materials locally; never publish or push."""
import argparse
import base64
from datetime import datetime, timezone
from email.utils import format_datetime
import hashlib
import html
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from urllib.parse import urlsplit
import xml.etree.ElementTree as ET

from install_local_trial import identity, manifest, ordinary_path, rename_exclusive, validate

SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
FEED_URL = 'https://raw.githubusercontent.com/danding9717/FinderNotes-updates/main/appcast.xml'
REPOSITORY_URL = 'https://github.com/danding9717/FinderNotes-updates'
KEYCHAIN_ACCOUNT = 'com.findernotes.FinderNotes.LocalTrial.updates'
DEFAULT_NOTES = '''新增“检查更新…”菜单，可手动查看新版本、下载并安装更新。
安装重启前保留现有草稿、保存与导出保护；返回编辑后可稍后重试。
这是个人本机使用版本，沿用 LocalTrial 身份，未进行 Apple 公证。
'''


def https_url(value):
    parsed = urlsplit(value)
    if (parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password
            or parsed.fragment or parsed.query):
        raise ValueError(f'Expected an HTTPS URL without credentials, query, or fragment: {value}')
    return value


def decode_base64(value, size, label):
    try:
        decoded = base64.b64decode(value, validate=True)
    except (ValueError, TypeError) as error:
        raise ValueError(f'Invalid {label}') from error
    if len(decoded) != size:
        raise ValueError(f'Invalid {label} length')
    return decoded


def verify_archive_signature(archive, signature, public_key):
    """Verify against the public key embedded in this app, not only the signer account."""
    swift = '''import Foundation
import CryptoKit
let arguments = CommandLine.arguments
let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: arguments[3])!)
let signature = Data(base64Encoded: arguments[2])!
let archive = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
if !publicKey.isValidSignature(signature, for: archive) { exit(1) }
'''
    subprocess.run(['/usr/bin/xcrun', 'swift', '-e', swift, str(archive), signature, public_key], check=True)


def make_appcast(info, archive_url, notes_url, signature, length, published_at):
    ET.register_namespace('sparkle', SPARKLE)
    rss = ET.Element('rss', {'version': '2.0'})
    channel = ET.SubElement(rss, 'channel')
    ET.SubElement(channel, 'title').text = 'FinderNotes 个人版本更新'
    ET.SubElement(channel, 'link').text = REPOSITORY_URL
    ET.SubElement(channel, 'description').text = 'FinderNotes 手动更新'
    ET.SubElement(channel, 'language').text = 'zh-CN'
    item = ET.SubElement(channel, 'item')
    ET.SubElement(item, 'title').text = f"FinderNotes {info['CFBundleShortVersionString']}（{info['CFBundleVersion']}）"
    ET.SubElement(item, f'{{{SPARKLE}}}version').text = info['CFBundleVersion']
    ET.SubElement(item, f'{{{SPARKLE}}}shortVersionString').text = info['CFBundleShortVersionString']
    ET.SubElement(item, f'{{{SPARKLE}}}minimumSystemVersion').text = info.get('LSMinimumSystemVersion', '26.0')
    ET.SubElement(item, f'{{{SPARKLE}}}releaseNotesLink').text = notes_url
    ET.SubElement(item, 'pubDate').text = format_datetime(published_at, usegmt=True)
    ET.SubElement(item, 'enclosure', {'url': archive_url, 'type': 'application/octet-stream',
                                    'length': str(length), f'{{{SPARKLE}}}edSignature': signature})
    ET.indent(rss)
    return ET.tostring(rss, encoding='utf-8', xml_declaration=True) + b'\n'


class PreparationFailure(RuntimeError):
    def __init__(self, message, evidence):
        super().__init__(message)
        self.evidence = evidence


def prepare(source, output, sign_update, *, account=KEYCHAIN_ACCOUNT, notes=DEFAULT_NOTES,
            release_base_url=None, validator=validate, signature_validator=verify_archive_signature):
    source = source.expanduser().absolute()
    output = output.expanduser().absolute()
    sign_update = sign_update.expanduser().absolute()
    ordinary_path(source)
    ordinary_path(output)
    if os.path.lexists(output):
        raise FileExistsError(f'Output already exists; use a new directory: {output}')
    if output.is_relative_to(source) or source.is_relative_to(output):
        raise ValueError('Application and output must be independent paths')
    if not sign_update.is_file() or not os.access(sign_update, os.X_OK):
        raise ValueError('Provide the executable Sparkle 2.10.0 sign_update tool')
    info, original = validator(source)
    source_identity = identity(source)
    public_key = info.get('SUPublicEDKey', '')
    decode_base64(public_key, 32, 'application SUPublicEDKey')
    if info.get('SUFeedURL') != FEED_URL or info.get('SUVerifyUpdateBeforeExtraction') is not True:
        raise ValueError('App must use the approved HTTPS feed and verify before extraction')
    if info.get('SURequireSignedFeed'):
        raise ValueError('Signed feeds require generate_appcast; this preparation uses archive signatures')
    version = info['CFBundleShortVersionString']
    build = info['CFBundleVersion']
    tag = f'v{version}-{build}'
    release_base_url = https_url(release_base_url or f'{REPOSITORY_URL}/releases/download/{tag}')
    archive_name = f'FinderNotes-{version}-{build}.zip'
    notes_name = f'FinderNotes-{version}-{build}.html'
    output.parent.mkdir(parents=True, exist_ok=True)
    ordinary_path(output.parent)
    stage = Path(tempfile.mkdtemp(prefix='.findernotes-update-', dir=output.parent))
    try:
        archive = stage / archive_name
        subprocess.run(['/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent',
                        str(source), str(archive)], check=True)
        # Round-trip confirms framework symlinks, executability, and source consistency.
        extracted = stage / 'verification'
        subprocess.run(['/usr/bin/ditto', '-x', '-k', str(archive), str(extracted)], check=True)
        _, archived = validator(extracted / source.name)
        if archived != original or manifest(source) != original or identity(source) != source_identity:
            raise ValueError('Archive round-trip differs or source changed')
        signed = subprocess.run([str(sign_update), '--account', account, '-p', str(archive)],
                                capture_output=True, text=True, check=True)
        signature = signed.stdout.strip()
        decode_base64(signature, 64, 'EdDSA archive signature')
        signature_validator(archive, signature, public_key)
        archive_sha256 = hashlib.sha256(archive.read_bytes()).hexdigest()
        length = archive.stat().st_size
        body = '\n'.join('<p>' + html.escape(paragraph) + '</p>'
                         for paragraph in notes.strip().splitlines() if paragraph.strip())
        release_notes = ('<!doctype html>\n<html lang="zh-CN"><meta charset="utf-8">'
                         '<meta name="viewport" content="width=device-width,initial-scale=1">'
                         '<title>FinderNotes 更新说明</title><body>'
                         f'<h1>FinderNotes {html.escape(version)}（{html.escape(build)}）</h1>'
                         + body + '</body></html>\n')
        (stage / notes_name).write_text(release_notes, encoding='utf-8')
        (stage / 'release-notes.txt').write_text(notes, encoding='utf-8')
        archive_url = release_base_url.rstrip('/') + '/' + archive_name
        notes_url = release_base_url.rstrip('/') + '/' + notes_name
        (stage / 'appcast.xml').write_bytes(make_appcast(info, archive_url, notes_url, signature,
                                                       length, datetime.now(timezone.utc)))
        (stage / 'SHA256SUMS').write_text(f'{archive_sha256}  {archive_name}\n', encoding='utf-8')
        result = {'status': 'prepared_locally', 'published': False, 'source': str(source),
                  'output': str(output), 'bundleID': info['CFBundleIdentifier'],
                  'version': version, 'build': build, 'releaseTag': tag, 'feedURL': FEED_URL,
                  'archiveURL': archive_url, 'releaseNotesURL': notes_url, 'archiveSHA256': archive_sha256,
                  'archiveLength': length, 'publicEDKey': public_key, 'signatureVerified': True,
                  'keychainAccount': account, 'filesSHA256': original,
                  'signatureScope': 'archive', 'appcastHistory': 'single release; merge with published feed before future releases'}
        (stage / 'preparation.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
        if manifest(source) != original or identity(source) != source_identity:
            raise ValueError('Source changed before preparation finished')
        shutil.rmtree(extracted)
        rename_exclusive(stage, output)
        return result
    except Exception as error:
        raise PreparationFailure(str(error), str(stage)) from error


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True, help='A new local directory')
    parser.add_argument('--sign-update', type=Path, required=True, help='Sparkle 2.10.0 bin/sign_update')
    parser.add_argument('--account', default=KEYCHAIN_ACCOUNT, help='Existing Keychain signing account; never creates keys')
    parser.add_argument('--notes-file', type=Path, help='UTF-8 Chinese release notes; plain text, one paragraph per line')
    parser.add_argument('--release-base-url', help='HTTPS fixed-version release download directory')
    args = parser.parse_args()
    try:
        notes = args.notes_file.read_text(encoding='utf-8') if args.notes_file else DEFAULT_NOTES
        result = prepare(args.source, args.output, args.sign_update, account=args.account,
                         notes=notes, release_base_url=args.release_base_url)
        print(json.dumps(result, ensure_ascii=False, indent=2))
    except (OSError, ValueError, subprocess.CalledProcessError, PreparationFailure) as error:
        result = {'status': 'failed', 'published': False, 'error': str(error)}
        if isinstance(error, PreparationFailure):
            result['evidenceDirectory'] = error.evidence
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
