#!/usr/bin/env python3
"""Exercise the actual production Media3 event policy without an Android device."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'android/app/src/main/kotlin/com/example/kazumi/NakuTVPlayerEvents.java'
HARNESS = ROOT / 'test/native/NakuTVPlayerEventsTest.java'


def jdk():
    candidates = [Path(os.environ['JAVA_HOME'])] if os.environ.get('JAVA_HOME') else []
    compiler = shutil.which('javac')
    if compiler:
        candidates.append(Path(compiler).resolve().parents[1])
    for candidate in candidates:
        if (candidate / 'bin/javac').is_file() and (candidate / 'bin/java').is_file():
            return candidate
    raise SystemExit('Set JAVA_HOME to an existing JDK 17+; no Android SDK is needed.')


def main():
    java = jdk()
    scratch = ROOT / '.dart_tool/tv_player_events_native'
    scratch.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='run-', dir=scratch) as directory:
        subprocess.run([str(java / 'bin/javac'), '-encoding', 'UTF-8', '-d', directory,
                        str(SOURCE), str(HARNESS)], check=True)
        subprocess.run([str(java / 'bin/java'), '-cp', directory,
                        'com.example.kazumi.NakuTVPlayerEventsTest'], check=True)
    print('Scope: production event/poll policy, exact snapshot reconstruction and metadata replay; physical TV frame rate/HDR remain device acceptance.')


if __name__ == '__main__':
    main()
