#!/usr/bin/env python3
"""Publish verified Android deltas and advance the matching legacy update feed."""
from __future__ import annotations

import argparse
import base64
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time
from urllib.parse import quote

from android_apk_delta import make_patch, sha256

REPO = 'NakuTop/NAKU-Player'
API = 'repos/' + REPO
ROOT = Path(__file__).resolve().parents[1]
CERT = '74bfc044f640358c9d8caf8cc4e8c640f34161f4a3f60dfbb345de9d91408349'
MAX_BYTES = 500 * 1024 * 1024
# Each patch goes directly to the new release, including for users skipping releases.
BASE_COUNT = 3
VERSION = r'\d+\.\d+\.\d+'


def run(*args, input_data=None):
    return subprocess.run([str(arg) for arg in args], input=input_data, check=True,
                          stdout=subprocess.PIPE, text=True).stdout.strip()


def api(path, *, payload=None):
    if payload is None:
        return json.loads(run('gh', 'api', API + '/' + path))
    return json.loads(run('gh', 'api', '--method', 'PUT', API + '/' + path, '--input', '-',
                          input_data=json.dumps(payload)))


def parse_tag(tag):
    mobile = re.fullmatch(f'v({VERSION})-android', tag)
    tv = re.fullmatch(f'android-tv-v({VERSION})\\+(\\d+)', tag)
    if mobile:
        return 'Mobile', mobile[1], None
    if tv:
        return 'TV', tv[1], int(tv[2])
    raise ValueError('Expected an official Android phone or TV release tag')


def apk_name(kind, version):
    return f'NAKU-TV-{version}-Android-universal.apk' if kind == 'TV' else f'NAKUPlayer-{version}-Android-Mobile.apk'


def apk_tag(kind, version, build):
    return f'android-tv-v{version}+{build}' if kind == 'TV' else f'v{version}-android'


def release(tag):
    result = api('releases/tags/' + quote(tag, safe=''))
    if result['draft'] or result['prerelease'] or result['tag_name'] != tag:
        raise ValueError('Expected a published stable release')
    return result


def asset_of(record, name):
    found = [a for a in record['assets'] if a['name'] == name and a['state'] == 'uploaded']
    if len(found) != 1:
        raise ValueError(f'Missing uploaded asset {name}')
    asset = found[0]
    tag = record['tag_name']
    expected = f'https://github.com/{REPO}/releases/download/{quote(tag, safe="")}/{name}'
    if (asset['browser_download_url'].replace('+','%2B') != expected or not
            re.fullmatch(r'sha256:[a-f0-9]{64}', asset.get('digest') or '') or
            not 0 < asset['size'] <= MAX_BYTES):
        raise ValueError(f'Invalid release metadata for {name}')
    return {k: asset[k] for k in ('name','state','size','digest','browser_download_url')}


def apk_file(record, asset, work, local_dirs):
    name = asset['name']
    path = next((d / name for d in local_dirs if (d / name).is_file()), work/name)
    if not path.exists():
        run('gh','release','download',record['tag_name'],'--repo',REPO,'--pattern',name,'--dir',work)
    if path.stat().st_size != asset['size'] or 'sha256:' + sha256(path) != asset['digest']:
        raise ValueError(f'APK differs from published asset {name}')
    return path


def inspect_apk(path, tools, kind, version, build):
    pkg = 'com.nakutop.nakuplayer' + ('.tv' if kind=='TV' else '')
    badging = run(tools/'aapt','dump','badging',path)
    match = re.search(r"^package: name='([^']+)' versionCode='(\d+)' versionName='([^']+)'",badging,re.M)
    if (not match or match[1] != pkg or match[3] != version or
            (build is not None and int(match[2]) != build) or
            (kind == 'TV' and 'leanback-launchable-activity:' not in badging)):
        raise ValueError(f'Wrong APK package, version or launcher: {path.name}')
    signatures = run(tools/'apksigner','verify','--verbose','--print-certs','--min-sdk-version','23',path)
    # Build Tools 37 labels the signer by scheme; older versions number it.
    certs = re.findall(
        r'^(?:Signer #\d+|V\d+(?:\.\d+)? Signer(?: #\d+)?:) certificate SHA-256 digest: ([a-f0-9]{64})$',
        signatures, re.M)
    if (set(certs) != {CERT} or 'Number of signers: 1' not in signatures.splitlines()
            or 'Verified using v1 scheme (JAR signing): true' not in signatures
            or 'Verified using v2 scheme (APK Signature Scheme v2): true' not in signatures):
        raise ValueError(f'Invalid official Android signature: {path.name}')
    return int(match[2])


def semver(text):
    if not isinstance(text,str) or not re.fullmatch(VERSION,text):
        raise ValueError('Invalid Android version')
    return tuple(map(int,text.split('.')))


def feed_version(record,kind):
    return parse_tag(record['tag_name'])[1] if kind=='TV' else record['tag_name']


def run_publish(args, work):
    kind, version, build = parse_tag(args.tag)
    tv = kind=='TV'
    name = 'android-tv-update.json' if tv else 'android-update.json'
    contents = api('contents/'+name+'?ref=main')
    previous = json.loads(base64.b64decode(contents['content']))
    latest = previous[0] if tv else previous
    old_version = feed_version(latest,kind)
    if semver(old_version) > semver(version) or (tv and semver(old_version)==semver(version) and parse_tag(latest['tag_name'])[2]>build):
        print('A newer Android feed is already live.')
        return
    record = release(args.tag)
    target_asset = asset_of(record,apk_name(kind,version))
    target = apk_file(record,target_asset,work,args.apk_dir)
    build = inspect_apk(target,args.build_tools,kind,version,build)
    same_release = (old_version==version and (not tv or latest['tag_name']==args.tag))
    old_asset = next(x for x in latest['assets'] if x['name']==apk_name(kind,old_version))
    old_build = parse_tag(latest['tag_name'])[2] if tv else old_asset.get('build')
    bases = [] if same_release else [(old_version,old_build,old_asset['digest'])]
    bases += [(row['base_version'],row['base_build'],'sha256:'+row['base_sha256'])
              for row in old_asset.get('deltas',[]) if row.get('format')=='gdiff4-gzip']
    bases = list(dict.fromkeys(bases))[:BASE_COUNT]
    if not bases and not same_release:
        raise ValueError('No predecessor available to verify a differential release')
    classes=work/'checks'
    classes.mkdir(exist_ok=True)
    run('javac','-encoding','UTF-8','-d',classes,
        ROOT/'android/app/src/main/kotlin/com/example/kazumi/NakuApkDelta.java',
        ROOT/'test/native/NakuApkDeltaCheck.java')
    deltas=[]
    for prior_version,prior_build,base_digest in bases:
        tag=apk_tag(kind,prior_version,prior_build)
        prior=release(tag)
        asset=asset_of(prior,apk_name(kind,prior_version))
        if asset['digest']!=base_digest:
            raise ValueError('Previously published base changed')
        base=apk_file(prior,asset,work,args.apk_dir)
        actual=inspect_apk(base,args.build_tools,kind,prior_version,prior_build)
        if not actual < build:
            raise ValueError('Base build must precede target build')
        patch=work/f'NAKU-{kind}-{actual}-{build}.gdiff.gz'
        already=next((a for a in record['assets'] if a['name']==patch.name),None)
        if already is None:
            make_patch(base,target,patch)
        else:
            # Different zlib versions may encode the same patch differently.
            # Re-run the client decoder against the exact published bytes.
            existing=asset_of(record,patch.name)
            with tempfile.TemporaryDirectory(dir=work) as remote_dir:
                downloaded=apk_file(record,existing,Path(remote_dir),[])
                shutil.copyfile(downloaded,patch)
        with tempfile.TemporaryDirectory(dir=work) as temp:
            run('java','-cp',classes,'com.example.kazumi.NakuApkDeltaCheck',base,patch,
                Path(temp)/'restored.apk',target)
        if patch.stat().st_size >= target.stat().st_size:
            print('Full APK is smaller than '+patch.name+'; keeping the full update for this base.')
            continue
        digest='sha256:'+sha256(patch)
        if already is None:
            run('gh','release','upload',args.tag,'--repo',REPO,patch)
        checked=asset_of(release(args.tag),patch.name)
        if checked['digest']!=digest or checked['size']!=patch.stat().st_size:
            raise ValueError('Published delta differs from locally verified delta')
        deltas.append({**checked,'format':'gdiff4-gzip','base_version':prior_version,
            'base_build':actual,'base_sha256':base_digest[7:],'target_sha256':target_asset['digest'][7:]})
        print(f'{kind} {actual} -> {build}: {checked["size"]} bytes, exact APK verified.',flush=True)
    target_asset.update({'build':build,'deltas':deltas})
    entry={k:record[k] for k in ['tag_name','name','body','html_url','published_at','draft','prerelease']}
    if not tv:
        entry['tag_name']=version
    entry['assets']=[target_asset]
    updated=([entry]+[r for r in previous if r['tag_name']!=args.tag][:7]) if tv else entry
    data=(json.dumps(updated,ensure_ascii=False,indent=2)+'\n').encode()
    (work/name).write_bytes(data)
    if data!=base64.b64decode(contents['content']):
        for attempt in range(4):
            try:
                api('contents/'+name,payload={'message':f'Publish {kind} differential update {version} ({build})',
                    'branch':'main','sha':contents['sha'],'content':base64.b64encode(data).decode()})
                break
            except subprocess.CalledProcessError:
                # Another channel can concurrently advance main. Never overwrite a new feed.
                fresh=api('contents/'+name+'?ref=main')
                if base64.b64decode(fresh['content'])==data:
                    break
                if fresh['sha']!=contents['sha'] or attempt==3:
                    raise
                time.sleep(2**attempt)
    remote=api('contents/'+name+'?ref=main')
    if base64.b64decode(remote['content'])!=data:
        raise ValueError('Published feed differs')
    print(f'{name} verified at {remote["sha"]}',flush=True)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tag',required=True)
    parser.add_argument('--apk-dir',type=Path,action='append',default=[])
    parser.add_argument('--build-tools',type=Path)
    parser.add_argument('--output',type=Path)
    args=parser.parse_args()
    if not args.build_tools:
        sdk=Path(os.environ.get('ANDROID_HOME') or os.environ['ANDROID_SDK_ROOT'])
        stable=[p for p in (sdk/'build-tools').iterdir() if re.fullmatch(VERSION,p.name)]
        args.build_tools=max(stable,key=lambda p:semver(p.name))
    if args.output:
        args.output.mkdir(parents=True,exist_ok=True)
        run_publish(args,args.output.resolve())
    else:
        with tempfile.TemporaryDirectory(prefix='naku-android-deltas-') as temp:
            run_publish(args,Path(temp))


if __name__=='__main__':
    main()
