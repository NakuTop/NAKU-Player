#!/usr/bin/env python3
"""Run the production certificate-read policy with old-TV API outcomes."""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'android/app/src/main/kotlin/com/example/kazumi/NakuTVUpdateSignatures.java'
HARNESS = ROOT / 'test/native/NakuTVUpdateSignaturesTest.java'

def main():
    java = Path(os.environ['JAVA_HOME']) / 'bin'
    with tempfile.TemporaryDirectory(prefix='naku-update-signatures-') as directory:
        subprocess.run([str(java / 'javac'), '-encoding', 'UTF-8', '-d', directory,
                        str(SOURCE), str(HARNESS)], check=True)
        subprocess.run([str(java / 'java'), '-cp', directory,
                        'com.example.kazumi.NakuTVUpdateSignaturesTest'], check=True)

if __name__ == '__main__':
    main()
