#!/usr/bin/env python3
"""Run native NAS playback fixtures without Flutter or a real NAS session."""
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    if sys.platform != "darwin":
        raise SystemExit("Native NAS playback fixtures require macOS and swiftc.")
    root = Path(__file__).resolve().parents[1]
    source = (root / "macos/Runner/NakuNASMovies.swift").read_text()
    core = source.replace("import FlutterMacOS", "").split("final class NakuNASMovies", 1)[0]
    with tempfile.TemporaryDirectory(prefix="naku-playback-fixtures-") as temp:
        folder = Path(temp)
        path = folder / "NASMovieCore.swift"
        path.write_text(core)
        binary = folder / "playback-fixtures"
        subprocess.run([
            "swiftc", str(path), str(root / "macos/Runner/NakuNASQR.swift"),
            str(root / "test/native/nas_playback_test.swift"), "-o", str(binary),
        ], check=True)
        subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    main()
