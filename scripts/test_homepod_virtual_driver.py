#!/usr/bin/env python3
"""Check the shipped output-only driver/client without installing or routing."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="naku-virtual-audio-test-") as temporary:
    work = Path(temporary)
    clang = ["xcrun", "clang", "-std=c11", "-fblocks", "-O2", "-Wall", "-Wextra", "-mmacosx-version-min=13.0"]
    frameworks = ["-framework", "CoreAudio", "-framework", "CoreFoundation"]
    cases = [
        (ROOT / "test/native/naku_audio_client_test.c", []),
        (ROOT / "macos/AudioDriver/Driver/tests/test_driver.c", frameworks + ["-Wno-unused-function"]),
        (ROOT / "test/native/naku_audio_broker_identity_test.c", ["-framework", "Security", "-framework", "CoreFoundation"]),
    ]
    for index, (source, flags) in enumerate(cases):
        executable = work / f"contract-{index}"
        subprocess.run(clang + [str(source), *flags, "-o", str(executable)], check=True)
        subprocess.run([str(executable)], check=True, timeout=20)
    subprocess.run(clang + ["-arch", "arm64", "-arch", "x86_64",
        str(ROOT / "macos/AudioDriver/Broker/NakuAudioBroker.c"), *frameworks,
        "-framework", "Security", "-framework", "SystemConfiguration", "-o", str(work / "broker")], check=True)
    subprocess.run(clang + ["-arch", "arm64", "-arch", "x86_64", "-bundle", "-fvisibility=hidden",
        str(ROOT / "macos/AudioDriver/Driver/NakuAudioDriver.c"), *frameworks, "-o", str(work / "driver")], check=True)
    print("PASS universal macOS 13+ broker and output-only driver compile")
