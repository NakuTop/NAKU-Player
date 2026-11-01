#!/usr/bin/env python3
"""Offline lifecycle cancellation and network-path contract; never routes audio."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="naku-homepod-session-") as temporary:
    work = Path(temporary)
    executable = work / "session-tests"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-O",
        "-module-cache-path", str(work / "module-cache"),
        str(ROOT / "macos/Runner/NakuHomePodSessionGuard.swift"),
        str(ROOT / "test/native/homepod_session_guard_test.swift"),
        "-o", str(executable),
    ], check=True)
    subprocess.run([str(executable)], check=True, timeout=20)
