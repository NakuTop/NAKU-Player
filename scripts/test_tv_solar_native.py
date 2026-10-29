#!/usr/bin/env python3
"""Compile and test the production pure-Java solar/texture policy, without Android.

Run from the project root: python3 scripts/test_tv_solar_native.py
Set JAVA_HOME to any JDK 17+; this machine's existing REA JDK is also recognized.
Reference fixture regeneration is separate and executes the original TS source.
"""
from pathlib import Path
import json
import os
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'android/app/src/main/kotlin/com/example/kazumi/NakuTVSolar.java'
HARNESS = ROOT / 'test/native/NakuTVSolarTest.java'
FIXTURES = ROOT / 'test/fixtures/tv_solar_reference.tsv'
PROVENANCE = ROOT / 'test/fixtures/tv_solar_reference.json'


def find_jdk():
    candidates = [Path(os.environ['JAVA_HOME'])] if os.environ.get('JAVA_HOME') else []
    candidates += [Path('/Users/shenminghao/Documents/Codex/tools/rea/providers/jdk-21.0.12.1+1/Contents/Home')]
    javac = shutil.which('javac')
    if javac and Path(javac).resolve() != Path('/usr/bin/javac'):
        candidates.append(Path(javac).resolve().parents[1])
    for candidate in candidates:
        if (candidate / 'bin/javac').is_file() and (candidate / 'bin/java').is_file():
            return candidate
    raise SystemExit('A JDK is required. Set JAVA_HOME to an existing JDK; no Android SDK is needed.')


def main():
    for filename in [SOURCE, HARNESS, FIXTURES, PROVENANCE]:
        if not filename.is_file():
            raise SystemExit(f'Required input is missing: {filename}')
    provenance = json.loads(PROVENANCE.read_text())
    assert len(provenance['fixtures']) >= 20
    assert len(provenance['sourceSha256']) == 4
    jdk = find_jdk()
    work = ROOT / '.dart_tool/tv_solar_native'
    work.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='run-', dir=work) as directory:
        subprocess.run([str(jdk / 'bin/javac'), '-encoding', 'UTF-8', '-d', directory, str(SOURCE), str(HARNESS)], check=True)
        for timezone in ['UTC', 'Asia/Shanghai', 'America/Los_Angeles', 'Pacific/Auckland']:
            env = dict(os.environ, TZ=timezone)
            subprocess.run([str(jdk / 'bin/java'), f'-Duser.timezone={timezone}', '-cp', directory,
                            'com.example.kazumi.NakuTVSolarTest', str(FIXTURES)], env=env, check=True)
    print(f'PASS: production NakuTVSolar.java; {len(provenance["fixtures"])} original-TS fixtures; 4 JVM timezones.')
    print('Scope: approximate visual sunlight + resource policy. Physical TV rendering, GPU allocation, resume wiring and decoder playback need device verification.')


if __name__ == '__main__':
    main()
