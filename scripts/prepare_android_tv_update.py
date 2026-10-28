#!/usr/bin/env python3
"""Verify a signed TV APK and prepare its dedicated update feed. Never publishes."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
from urllib.parse import quote
import zipfile

SIGNER = '74bfc044f640358c9d8caf8cc4e8c640f34161f4a3f60dfbb345de9d91408349'


def run(*args: str | Path) -> str:
    return subprocess.run([str(arg) for arg in args], check=True, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT).stdout


def prepare(apk: Path, version: str, build: int, output: Path,
            build_tools: Path, notes: str) -> dict:
    if not re.fullmatch(r'\d+\.\d+\.\d+', version) or build <= 0:
        raise ValueError('Use a numeric x.y.z TV version and positive Android build')
    badging = run(build_tools / 'aapt', 'dump', 'badging', apk)
    expected = f"package: name='com.nakutop.nakuplayer.tv' versionCode='{build}' versionName='{version}'"
    if expected not in badging or 'leanback-launchable-activity:' not in badging:
        raise ValueError('APK package, version, build or TV launcher is incorrect')
    certificate = run(build_tools / 'apksigner', 'verify', '--verbose', '--print-certs', apk)
    if 'Verifies' not in certificate or f'Signer #1 certificate SHA-256 digest: {SIGNER}' not in certificate:
        raise ValueError('APK is not signed with the existing NAKU Android release certificate')
    with zipfile.ZipFile(apk) as archive:
        if archive.testzip() is not None:
            raise ValueError('APK ZIP integrity check failed')
    if not 0 < apk.stat().st_size <= 500 * 1024 * 1024:
        raise ValueError('APK size exceeds TV updater bounds')
    sha = hashlib.sha256()
    with apk.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            sha.update(chunk)
    digest = sha.hexdigest()
    name = f'NAKU-TV-{version}-Android-universal.apk'
    tag = f'android-tv-v{version}+{build}'
    record = [{
        'tag_name': tag, 'draft': False, 'prerelease': False, 'body': notes,
        'assets': [{
            'name': name, 'state': 'uploaded', 'size': apk.stat().st_size,
            'digest': f'sha256:{digest}',
            'browser_download_url': f'https://github.com/NakuTop/NAKU-Player/releases/download/{quote(tag, safe="")}/{name}',
        }],
    }]
    output.mkdir(parents=True, exist_ok=True)
    destination = output / name
    if apk.resolve() != destination.resolve():
        shutil.copy2(apk, destination)
    (output / 'SHA256SUMS').write_text(f'{digest}  {name}\n')
    (output / 'android-tv-update.json').write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n')
    return {'tag': tag, 'apk': str(destination), 'sha256': digest,
            'feed': str(output / 'android-tv-update.json'), 'published': False}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apk', type=Path, required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--build', type=int, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--build-tools', type=Path, required=True)
    parser.add_argument('--notes-file', type=Path)
    args = parser.parse_args()
    notes = args.notes_file.read_text() if args.notes_file else 'NAKU TV 更新'
    print(json.dumps(prepare(args.apk, args.version, args.build, args.output,
                             args.build_tools, notes), ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
