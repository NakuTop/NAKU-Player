#!/usr/bin/env python3
"""Verify an already signed universal macOS app and create release archives.

This script never signs the app, accesses signing keys, or publishes artifacts.
Only the Python standard library and macOS developer/system tools are used.
"""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile


DISPLAY_NAME = "NAKU播放器.app"
ARCHITECTURES = {"arm64", "x86_64"}
MACH_O_MAGIC = {
    b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
}


def run(*args: str | Path) -> str:
    result = subprocess.run(
        [str(arg) for arg in args],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    return result.stdout.strip()


def verify_app(app: Path, version: str) -> None:
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    actual_version = str(info.get("CFBundleShortVersionString", ""))
    if actual_version != version:
        raise ValueError(
            f"App version {actual_version!r} does not match --version {version!r}"
        )
    executable = info.get("CFBundleExecutable")
    if not isinstance(executable, str) or Path(executable).name != executable:
        raise ValueError("Invalid or missing CFBundleExecutable")
    framework_root = app / "Contents/Frameworks"
    required = [app / "Contents/MacOS" / executable]
    for framework in ("App", "FlutterMacOS", "Sparkle"):
        required.append(framework_root / f"{framework}.framework" / framework)
    for binary in required:
        if not binary.is_file():
            raise ValueError(f"Required binary is missing: {binary.relative_to(app)}")

    run("codesign", "--verify", "--deep", "--strict", "--verbose=2", app)

    # Inspect actual Mach-O files, including embedded Sparkle XPC executables;
    # framework aliases are resolved once so symlinks are not checked twice.
    binaries: set[Path] = {binary.resolve() for binary in required}
    for directory, _, files in os.walk(app / "Contents", followlinks=False):
        for name in files:
            path = Path(directory) / name
            if not path.is_file():
                continue
            with path.open("rb") as stream:
                if stream.read(4) in MACH_O_MAGIC:
                    binaries.add(path.resolve())
    for binary in sorted(binaries):
        if not binary.is_relative_to(app.resolve()):
            raise ValueError("An embedded executable resolves outside the app")
        archs = set(run("lipo", "-archs", binary).split())
        if not ARCHITECTURES.issubset(archs):
            relative = binary.relative_to(app.resolve())
            raise ValueError(f"Not universal: {relative} contains {sorted(archs)}")
    print(f"Verified code signature and both architectures in {len(binaries)} binaries.")


def installation_text(version: str) -> str:
    return f"""NAKU播放器 {version}

安装要求：macOS 12 或更新版本；支持 Apple Silicon 和 Intel。

1. 将“NAKU播放器.app”拖入“Applications”（应用程序）文件夹。
2. 从应用程序中打开 NAKU播放器，不要直接从 DMG 运行。
3. 从映川或旧版 NAKU 升级时先退出旧程序；正常替换应用会保留片源、收藏和观看记录。

当前公开版本采用本地 ad-hoc 签名，未通过 Apple Developer ID 公证。
若系统阻止首次打开，先核对官方发布来源和 SHA256SUMS，再到
“系统设置 → 隐私与安全性”选择“仍要打开”。无需关闭系统安全功能。

一起看：在首页或播放器打开“一起看”，填写同一个 Syncplay 服务器
和房间名，并使用不同昵称。配对会保留到主动解除；对方开始观看后，
可点击“跟随观看”，匹配本机片源中的同一作品和集数并同步进度。
成功同步后对方会收到提示；双方均需可播放的片源和网络。
不传输影片、播放地址或屏幕。
默认服务器为 syncplay.pl:8996，连接使用 TLS。只向同伴分享随机房间名。
不同版本的片头或剪辑可能有时间差，可手动校准进度。

软件更新：在“软件更新”中检查版本；自动安装可由用户自行开启。
正式更新目录和安装包使用 Ed25519 签名验证。

下载、源码、更新记录与问题反馈：
https://github.com/NakuTop/NAKU-Player
详细一起看说明：
https://github.com/NakuTop/NAKU-Player/blob/main/docs/WATCH_TOGETHER.md

本软件基于 Kazumi，按 GPL-3.0 发布，保留相关组件的许可证。
不存储或分发影视文件，请依据内容授权使用来源。
"""


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def package(app: Path, output: Path, version: str) -> None:
    if sys.platform != "darwin":
        raise ValueError("Packaging requires macOS")
    for tool in ("codesign", "lipo", "ditto", "hdiutil"):
        if shutil.which(tool) is None:
            raise ValueError(f"Required macOS tool is unavailable: {tool}")
    if not app.is_dir() or app.suffix != ".app":
        raise ValueError("--app must point to an existing .app bundle")
    if output == app or output.is_relative_to(app):
        raise ValueError("--output must be outside the app bundle")
    stem = f"NAKUPlayer-{version}-macOS-universal"
    filenames = [f"{stem}.zip", f"{stem}.dmg", "INSTALL-zh-CN.txt", "SHA256SUMS"]
    for name in filenames:
        if (output / name).exists():
            raise ValueError(f"Refusing to overwrite existing release artifact: {name}")
    verify_app(app, version)
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".naku-package-", dir=output) as temporary:
        work = Path(temporary)
        stage = work / "release"
        stage.mkdir()
        staged_app = stage / DISPLAY_NAME
        run("ditto", app, staged_app)
        # Verify the copied bundle before including it in either archive.
        run("codesign", "--verify", "--deep", "--strict", staged_app)
        (stage / "Applications").symlink_to("/Applications", target_is_directory=True)
        guide = work / "INSTALL-zh-CN.txt"
        guide.write_text(installation_text(version), encoding="utf-8")
        shutil.copyfile(guide, stage / guide.name)
        zip_path = work / filenames[0]
        # No enclosing directory: Sparkle finds the one app at archive root.
        run("ditto", "-c", "-k", "--sequesterRsrc", stage, zip_path)
        dmg_path = work / filenames[1]
        run(
            "hdiutil", "create", "-volname", f"NAKU播放器 {version}",
            "-srcfolder", stage, "-format", "UDZO", "-ov", dmg_path,
        )
        run("hdiutil", "verify", dmg_path)
        # Archive extraction must preserve the app signature and install alias.
        extracted = work / "zip-check"
        run("ditto", "-x", "-k", zip_path, extracted)
        run("codesign", "--verify", "--deep", "--strict", extracted / DISPLAY_NAME)
        if not (extracted / "Applications").is_symlink():
            raise ValueError("ZIP did not preserve the Applications symlink")
        artifacts = [zip_path, dmg_path, guide]
        manifest = work / "SHA256SUMS"
        manifest.write_text(
            "".join(f"{sha256(path)}  {path.name}\n" for path in artifacts),
            encoding="utf-8",
        )
        # Publish locally only after all checks pass. No partial artifacts are
        # written when signing, architecture, or archive validation fails.
        for artifact in [*artifacts, manifest]:
            artifact.rename(output / artifact.name)
    print(f"Created {filenames[0]}, {filenames[1]}, INSTALL-zh-CN.txt and SHA256SUMS")
    print("The app was not modified or re-signed. Sign the ZIP and appcast before publishing.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True, help="Already signed universal .app bundle")
    parser.add_argument("--output", type=Path, required=True, help="Release artifact directory")
    parser.add_argument("--version", required=True, help="Exact CFBundleShortVersionString, e.g. 1.0.0")
    args = parser.parse_args()
    if not re.fullmatch(r"\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?", args.version):
        parser.error("--version must be a dotted semantic version such as 1.0.0")
    try:
        package(args.app.expanduser().resolve(), args.output.expanduser().resolve(), args.version)
    except subprocess.CalledProcessError as error:
        print(f"Packaging failed: {error.cmd[0]} exited {error.returncode}", file=sys.stderr)
        if error.stdout:
            print(error.stdout.rstrip(), file=sys.stderr)
        return 1
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        print(f"Packaging failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
