#!/usr/bin/env python3
"""Create only new synthetic fixtures; no existing media is read."""
import hashlib, json, os, pathlib, shutil, struct, subprocess, tempfile, zlib
root = pathlib.Path(tempfile.mkdtemp(prefix='findernotes-fn02-')).resolve()
def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 8, 8, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress((b'\0' + b'\x20\x80\xff'*8)*8)) + chunk(b'IEND', b'')
(root/'seed.png').write_bytes(png)
subprocess.run(['/opt/homebrew/bin/ffmpeg', '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i', 'color=c=blue:s=16x16:r=1:d=1', '-c:v', 'mpeg4', '-n', str(root/'seed.mov')], check=True)
(root/'work').mkdir()
for ext in ('png', 'mov'):
    for name in ('normal', 'readonly', 'unreadable', 'disappear', 'replace', 'replacement', 'conflict', 'hard', 'invalid'):
        p=root/'work'/f'{name}.{ext}'
        shutil.copyfile(root/f'seed.{ext}', p)
        subprocess.run(['/usr/bin/xattr', '-w', 'com.findernotes.fn02.sentinel', 'preserve-me', str(p)], check=True)
    os.chmod(root/'work'/f'readonly.{ext}', 0o444)
    os.chmod(root/'work'/f'unreadable.{ext}', 0)
    os.symlink(f'normal.{ext}', root/'work'/f'symlink.{ext}')
    os.link(root/'work'/f'hard.{ext}', root/'work'/f'hard-link.{ext}')
    subprocess.run(['/usr/bin/xattr', '-wx', 'com.findernotes.note.v1', 'ff', str(root/'work'/f'invalid.{ext}')], check=True)
(root/'work'/'directory.png').mkdir()
config={'root':str(root), 'seedHashes':{ext:hashlib.sha256((root/f'seed.{ext}').read_bytes()).hexdigest() for ext in ('png','mov')}}
(root/'run.json').write_text(json.dumps(config, indent=2)+'\n')
print(root)
