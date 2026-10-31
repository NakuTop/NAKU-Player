#!/usr/bin/env python3
"""Compile the shipped sender and run offline protocol/crypto fixtures only."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

with tempfile.TemporaryDirectory(prefix="naku-homepod-sender-") as temporary:
    work = Path(temporary)
    sources = sorted((ROOT / "third_party/swift-bigint/Sources").glob("*.swift"))
    sources += [ROOT / "macos/Runner/NakuAirPlaySender.swift",
                ROOT / "test/native/homepod_sender_test.swift"]
    executable = work / "sender-tests"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-O",
        "-module-cache-path", str(work / "module-cache"),
        *map(str, sources), "-o", str(executable),
    ], check=True)
    subprocess.run([str(executable), "--self-test"], check=True, timeout=30)
