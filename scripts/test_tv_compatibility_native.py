#!/usr/bin/env python3
"""Compile and execute production TV color and aircraft geometry policies with Java 17+."""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
java = Path(os.environ['JAVA_HOME']) / 'bin'
source = ROOT / 'android/app/src/main/kotlin/com/example/kazumi'
scratch = ROOT / '.dart_tool/tv_compatibility_native'
scratch.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(dir=scratch) as output:
    subprocess.run([str(java / 'javac'), '-encoding', 'UTF-8', '-d', output,
                    str(source / 'NakuTVColorPolicy.java'), str(source / 'NakuTVFlightPath.java'),
                    str(ROOT / 'test/native/NakuTVCompatibilityTest.java')], check=True)
    subprocess.run([str(java / 'java'), '-cp', output, 'NakuTVCompatibilityTest'], check=True)
