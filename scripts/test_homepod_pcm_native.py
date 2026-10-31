#!/usr/bin/env python3
"""Compile the exact native tap and test PCM fixtures without recording audio."""
from pathlib import Path
import platform
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="naku-homepod-pcm-") as scratch:
    scratch = Path(scratch)
    main = scratch / "main.swift"
    main.write_bytes((root / "test/native/homepod_pcm_test.swift").read_bytes())
    binary = scratch / "pcm-test"
    native = scratch / "client.o"
    subprocess.run(["xcrun", "clang", "-std=c11", "-fblocks", "-O2", "-mmacosx-version-min=13.0", "-c", str(root / "macos/Runner/NakuAudioClient.c"), "-o", str(native)], check=True)
    subprocess.run([
        "xcrun", "swiftc", "-O", "-swift-version", "5", "-target", f"{platform.machine()}-apple-macos13.0",
        "-module-cache-path", str(scratch / "modules"),
        "-import-objc-header", str(root / "macos/Runner/NakuAudioClient.h"),
        str(root / "macos/Runner/NakuPCMProcessTap.swift"), str(root / "macos/Runner/NakuVirtualAudio.swift"), str(native), str(main), "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True, timeout=20)
