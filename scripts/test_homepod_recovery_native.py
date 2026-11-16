#!/usr/bin/env python3
"""Run the production session controller with inert audio/transport fixtures."""
from pathlib import Path
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='naku-recovery-') as directory:
    work = Path(directory)
    # Visibility only: execute the real lifecycle, timers and callbacks. No
    # driver routing, network packets, credentials or saved user defaults.
    source = (ROOT / 'macos/Runner/NakuHomePodAudio.swift').read_text()
    source = source.replace('private ', '').replace('UserDefaults.standard', 'UserDefaults(suiteName: "naku-recovery-fixture")!')
    (work / 'Controller.swift').write_text(source)
    exe = work / 'tests'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-O', '-module-cache-path', str(work / 'cache'),
                    str(work / 'Controller.swift'), str(ROOT / 'macos/Runner/NakuHomePodSessionGuard.swift'),
                    str(ROOT / 'test/native/homepod_recovery_stubs.swift'), str(ROOT / 'test/native/homepod_recovery_test.swift'),
                    '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True, timeout=20)
