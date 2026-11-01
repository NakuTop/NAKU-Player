#!/usr/bin/env python3
"""Add a verified Sparkle delta to an existing release; retain full enclosure.
Run after publishing the complete archive and before activating appcast.xml.
"""
import argparse, base64, hashlib, json, plistlib, subprocess, tempfile
from pathlib import Path
import xml.etree.ElementTree as ET

p=argparse.ArgumentParser(description=__doc__)
for name in ('old-archive','new-archive','feed','sparkle-bin'):
    p.add_argument('--'+name,type=Path,required=True)
p.add_argument('--repository',default='NakuTop/NAKU-Player')
p.add_argument('--account',default='NakuTop.NAKUPlayer')
a=p.parse_args()
def run(*args):
    return subprocess.check_output([str(x) for x in args],stderr=subprocess.STDOUT)
ns='http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle',ns)
with tempfile.TemporaryDirectory(prefix='naku-delta-') as temp:
    root=Path(temp)
    apps=[]
    infos=[]
    for label,archive in [('old',a.old_archive),('new',a.new_archive)]:
        dest=root/label
        run('ditto','-x','-k',archive.resolve(),dest)
        found=list(dest.glob('*.app'))
        if len(found)!=1: raise ValueError('Expected exactly one app')
        app=found[0]
        run('codesign','--verify','--deep','--strict',app)
        apps.append(app)
        infos.append(plistlib.loads((app/'Contents/Info.plist').read_bytes()))
    old,new=infos
    if old['CFBundleIdentifier']!=new['CFBundleIdentifier']: raise ValueError('Bundle mismatch')
    if int(old['CFBundleVersion'])>=int(new['CFBundleVersion']): raise ValueError('Build must increase')
    version=new['CFBundleShortVersionString']
    name=f"NAKUPlayer-{new['CFBundleVersion']}-{old['CFBundleVersion']}.delta"
    patch=a.new_archive.resolve().parent/name
    run(a.sparkle_bin/'BinaryDelta','create','--version=4',apps[0],apps[1],patch)
    patched=root/'patched.app'
    run(a.sparkle_bin/'BinaryDelta','apply',apps[0],patched,patch)
    run('codesign','--verify','--deep','--strict',patched)
    def contents(app):
        return {str(f.relative_to(app)): ('link',str(f.readlink())) if f.is_symlink() else ('file',hashlib.sha256(f.read_bytes()).hexdigest(),f.stat().st_mode & 0o777) for f in app.rglob('*') if f.is_symlink() or f.is_file()}
    if contents(patched)!=contents(apps[1]): raise ValueError('Patched app differs from release')
    signature=run(a.sparkle_bin/'sign_update','--account',a.account,'-p',patch).decode().strip()
    run(a.sparkle_bin/'sign_update','--account',a.account,'--verify',patch,signature)
    tree=ET.parse(a.feed)
    item=next(i for i in tree.getroot().findall('channel/item') if i.findtext('{'+ns+'}version')==str(new['CFBundleVersion']))
    if item.find('enclosure') is None: raise ValueError('Full fallback is required')
    deltas=item.find('{'+ns+'}deltas')
    if deltas is None: deltas=ET.SubElement(item,'{'+ns+'}deltas')
    if any(e.get('{'+ns+'}deltaFrom')==str(old['CFBundleVersion']) for e in deltas): raise ValueError('Delta already present')
    ET.SubElement(deltas,'enclosure',{'url':f'https://github.com/{a.repository}/releases/download/v{version}/{name}','length':str(patch.stat().st_size),'type':'application/octet-stream','{'+ns+'}deltaFrom':str(old['CFBundleVersion']),'{'+ns+'}edSignature':signature})
    # Upload only after reconstruction and signature validation; never clobber.
    run('gh','release','upload','v'+version,'--repo',a.repository,patch)
    target=root/name
    run('curl','-q','-fLsS',f'https://github.com/{a.repository}/releases/download/v{version}/{name}','-o',target)
    if hashlib.sha256(target.read_bytes()).digest()!=hashlib.sha256(patch.read_bytes()).digest(): raise ValueError('Public delta mismatch')
    tree.write(a.feed,encoding='utf-8',xml_declaration=True)
    run(a.sparkle_bin/'sign_update','--account',a.account,a.feed)
    run(a.sparkle_bin/'sign_update','--account',a.account,'--verify',a.feed)
    print(json.dumps({'delta':name,'bytes':patch.stat().st_size,'sha256':hashlib.sha256(patch.read_bytes()).hexdigest(),'reconstruction_verified':True,'full_fallback_preserved':True}))
