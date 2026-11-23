"""Prepare verified per-ABI executables in Gradle's generated directories."""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from urllib.request import urlopen

VERSION = 'MatriX.151'
ENGINES = {
    'arm64-v8a': ('arm64', 'aarch64-linux-android', 'f32b80f0c428c25d7d91c8bd22ac0d13f6c6ff35b38da42a38aa2fadfa4bc31a'),
    'armeabi-v7a': ('arm7', 'armv7a-linux-androideabi', '29f803f2a94b216a4ec5ab7dd3f75ffaa24ab9f5f5dcf335cb437a0540d02d28'),
    'x86_64': ('amd64', 'x86_64-linux-android', 'a3ea581305aa724bcdc277f12154d3289b12ee61b02ae04f38582b91b0986eb3'),
}

def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()

def verified_engine(cache, name, expected):
    path = cache / ('TorrServer-android-' + name)
    if path.is_file() and digest(path) == expected:
        return path
    url = f'https://github.com/YouROK/TorrServer/releases/download/{VERSION}/{path.name}'
    with tempfile.NamedTemporaryFile(dir=cache, delete=False) as remote:
        tmp = Path(remote.name)
        try:
            with urlopen(url, timeout=120) as response:
                shutil.copyfileobj(response, remote)
            remote.flush()
            if digest(tmp) != expected:
                raise ValueError(f'Unexpected TorrServer digest for {name}')
            remote.close()
            tmp.replace(path)
        finally:
            tmp.unlink(missing_ok=True)
    return path

def main():
    parser = argparse.ArgumentParser()
    for name in ('ndk', 'out', 'cache'):
        parser.add_argument('--' + name, required=True, type=Path)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    args.cache.mkdir(parents=True, exist_ok=True)
    llvm = next((args.ndk / 'toolchains/llvm/prebuilt').glob('*/bin/clang*'))
    clang = llvm.parent / ('clang.exe' if os.name == 'nt' else 'clang')
    for abi, (name, triple, expected) in ENGINES.items():
        directory = args.out / 'jniLibs' / abi
        directory.mkdir(parents=True, exist_ok=True)
        engine = verified_engine(args.cache, name, expected)
        shutil.copyfile(engine, directory / 'libnaku_torrserver.so')
        subprocess.run([str(clang), '--target=' + triple + '23', '-Wall', '-Wextra', '-Werror',
                        '-Os', '-fPIE', '-pie', '-Wl,-z,max-page-size=16384',
                        str(repo / 'android/app/src/main/cpp/naku_original_host.c'),
                        '-o', str(directory / 'libnaku_original_host.so')], check=True)
    assets = args.out / 'assets/OriginalMedia'
    assets.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(repo / 'macos/OriginalMedia/LICENSE-TorrServer', assets / 'LICENSE')
    (assets / 'Source.txt').write_text(f'TorrServer {VERSION} — https://github.com/YouROK/TorrServer/tree/{VERSION}\n')

if __name__ == '__main__':
    main()
