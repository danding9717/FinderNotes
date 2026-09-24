#!/usr/bin/env python3
"""Independent, read-only media/xattr oracle, using Apple's xattr utility."""
import hashlib, json, pathlib, subprocess, sys
root=pathlib.Path(sys.argv[1]).resolve()
config=json.loads((root/'run.json').read_text())
assert config['root']==str(root) and root.name.startswith('findernotes-fn02-')
key='com.findernotes.note.v1'
checks=[]
mode=sys.argv[2] if len(sys.argv)>2 else 'inspect'
expected={}
if mode=='self-test':
    expected={f'normal.{ext}':f'FN02 中文🙂\n失败可复制草稿 {ext}  '.encode() for ext in ('png','mov')}
elif mode=='ui':
    expected={'normal.png':'FN02 最终构建重复触发🙂'.encode(), 'normal.mov':'FN02 MOV 热启动 中文🙂'.encode()}
else:
    assert mode=='inspect'
def attrs(p):
    names=subprocess.check_output(['/usr/bin/xattr',str(p)],text=True).splitlines()
    return {n:bytes.fromhex(subprocess.check_output(['/usr/bin/xattr','-px',n,str(p)],text=True)) for n in names}
for p in sorted((root/'work').iterdir()):
    if not p.is_file() or p.is_symlink() or p.name.startswith('unreadable.'):
        continue
    assert hashlib.sha256(p.read_bytes()).hexdigest()==config['seedHashes'][p.suffix[1:]], p
    a=attrs(p)
    assert a.get('com.findernotes.fn02.sentinel')==b'preserve-me', p
    if p.name in expected:
        assert a.get(key)==expected[p.name], ('note mismatch',p)
    checks.append({'file':p.name,'media_matches_seed':True,'sentinel_preserved':True,'note':None if key not in a else a[key].hex()})
    if p.name.startswith(('readonly.','replace.','hard.','hard-link.')):
        assert key not in a, ('unexpected write',p)
print(json.dumps({'root':str(root),'ok':True,'checks':checks},ensure_ascii=False,indent=2))
