#!/usr/bin/env python3
"""Measure the packaged MPV library against a supplied local video fixture."""
import argparse
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--app', type=Path, required=True)
parser.add_argument('--fixture', type=Path, required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
frameworks = args.app.resolve() / 'Contents/Frameworks'
with tempfile.TemporaryDirectory(prefix='naku-rate-test-') as temp:
    binary = Path(temp) / 'rate-test'
    subprocess.run(['clang', str(root / 'test/native/playback_rate_test.c'),
                    '-I', str(root / 'third_party/media_kit_video/common/mpv/include'),
                    '-F', str(frameworks), '-framework', 'Mpv',
                    f'-Wl,-rpath,{frameworks}', '-o', str(binary)], check=True)
    subprocess.run([str(binary), str(args.fixture.resolve())], check=True, timeout=30)
