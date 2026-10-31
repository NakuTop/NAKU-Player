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


def minimum_os_versions(load_commands: str) -> list[tuple[int, ...]]:
    # Match deployment commands only, never a dylib's unrelated current version.
    values = re.findall(r"\bminos ([0-9.]+)", load_commands)
    values += re.findall(r"cmd LC_VERSION_MIN_MACOSX\s+cmdsize \d+\s+version ([0-9.]+)", load_commands)
    return [tuple(int(part) for part in value.split('.')) + (0,) * (3 - len(value.split('.'))) for value in values]


def verify_app(app: Path, version: str) -> None:
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    actual_version = str(info.get("CFBundleShortVersionString", ""))
    if info.get("CFBundleIdentifier") != "com.shenminghao.yingchuan":
        raise ValueError("The bundle identifier changed; this would disconnect existing user data")
    if actual_version != version:
        raise ValueError(
            f"App version {actual_version!r} does not match --version {version!r}"
        )
    if int(version.split('.')[0]) >= 2 and not any(
        'naku' in item.get('CFBundleURLSchemes', [])
        for item in info.get('CFBundleURLTypes', [])
        if isinstance(item, dict)
    ):
        raise ValueError('NAKU 2.0 invitation URL scheme is missing')
    minimum = str(info.get("LSMinimumSystemVersion", ""))
    if not re.fullmatch(r"\d+\.\d+(?:\.\d+)?", minimum):
        raise ValueError("Invalid or missing LSMinimumSystemVersion")
    declared_minimum = tuple(int(part) for part in minimum.split('.')) + (0,) * (3 - len(minimum.split('.')))
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
    entitlement_dump = run("codesign", "-d", "--entitlements", ":-", app)
    entitlement_xml = re.search(r"<\?xml.*?</plist>", entitlement_dump, re.S)
    if entitlement_xml is None or plistlib.loads(entitlement_xml[0].encode()).get("com.apple.security.app-sandbox") is not True:
        raise ValueError("The macOS sandbox/data domain changed; preserve the existing container")

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
        required_os = minimum_os_versions(run("otool", "-l", binary))
        if any(value > declared_minimum for value in required_os):
            raise ValueError(f"Minimum macOS mismatch: {binary.relative_to(app.resolve())} requires a newer OS than {minimum}")
    print(f"Verified code signature, both architectures and macOS {minimum} minimum in {len(binaries)} binaries.")


def installation_text(version: str, minimum_macos: str) -> str:
    return f"""NAKU播放器 {version}

安装要求：macOS {minimum_macos} 或更新版本；支持 Apple Silicon 和 Intel。

1. 解压 ZIP 或打开 DMG，将“NAKU播放器.app”拖入“Applications”（应用程序）文件夹。
2. 从应用程序中打开 NAKU播放器，不要直接从 DMG 运行。
3. 从映川或旧版 NAKU 升级时先退出旧程序；正常替换应用会保留片源、收藏、观看和下载记录。

此安装包采用本地 ad-hoc 签名，未通过 Apple Developer ID 公证。
若系统阻止首次打开，先核对官方发布来源和 SHA256SUMS，再到
“系统设置 → 隐私与安全性”选择“仍要打开”。无需关闭系统安全功能。

一起看：在首页或播放器打开“一起看”，填写同一个 Syncplay 服务器
和房间名，并使用不同昵称。配对会保留到主动解除；对方开始观看后，
可点击“跟随观看”，匹配本机片源中的同一作品和集数并同步进度。
成功同步后对方会收到提示；双方均需可播放的片源和网络。
不传输影片、播放地址或屏幕。
默认服务器为 syncplay.pl:8996，连接使用 TLS。只向同伴分享随机房间名。
不同版本的片头或剪辑可能有时间差，2.0 起可在一起看面板设置独立时间偏移。
双方使用 2.0 时默认协调缓冲等待；手动暂停不会被缓冲恢复覆盖。
2.0 邀请：详情页、播放器或一起看面板可复制链接 / 显示二维码；
对方安装 2.0 后打开链接并确认，或在设置的“打开作品邀请”中粘贴。
动漫与影视共用房间，动漫由 Bangumi 编号和对方动漫规则解析。

2.0 设置 → 播放缓存与片库迁移：可批量导入 / 订阅片源，调整 HLS 预缓存及下一集预热，
导出 / 合并完整片库。账号凭据默认排除；视频文件需另外复制下载目录。
字幕、音轨、双字幕和延迟，以及截图，位于影视播放器下方及全屏工具栏；在线字幕搜索位于字幕与音轨面板。

离线：详情页点“下载”或播放器点“下载选集”，可多选或全选一季；
从主侧栏“下载管理”播放。网络失败可在“网络设置”选择“视频直连”。
动漫弹幕：播放和换集自动匹配 Bilibili 弹幕，无需粘贴链接。
匹配不明确时，在“弹幕切换”确认一次版本与集数；保留 XML/JSON 导入。

2.11.2 下载保护：数据库占用或读取失败时保留数据并提示退出其他版本；
下载索引为空时可从独立索引及现有视频恢复。更新时请先完全退出旧版，
不要删除应用数据目录。历史重复视频会保留并标注，不能视为不同集数。

2.12.1：默认电影、剧集为近期热门及全部年份；卡片显示资源查找状态。
同片普通版与 4K 版合并，默认优先选择带 4K 标签的版本；播放时探测真实画质。
修复国语、4K 标签导致的跨站评分缺失，缩短临时失败重试间隔。

2.12.2：修复剧集资料跳转被误判为访问受限的问题，补查缺失的跨站评分。
跨站索引缺项时核对官网片名、年份和类型；IMDb 每日数据缺项时补查官网。
IMDb 整剧评分与烂番茄当季评分分别注明，官网未公布的分数保持为空。

软件更新：在“软件更新”中检查版本；自动安装可由用户自行开启。
2.12.4 补齐首页持久缓存：完全退出后恢复目录、资源状态、评分和封面。
过期内容在后台逐项更新；保留 2.x 收官版的美剧评分、影评修复与原有功能数据。
正式更新目录和安装包使用 Ed25519 签名验证。

3.0 影院界面：原生磨砂玻璃、悬浮导航、统一影视搜索与大海报墙；
首页及高清详情图边缘渐隐到磨砂背景，目录每批加载40部。
详情按实际资源就绪逐步清晰；播放首帧到达后灯管才点亮。
下载、收藏、历史、设置及榜单沿用相同材质与转场；保留原片库和视频。

3.0.1 Home Display：首页 NAS 旁新增入口，原生网页实时显示地球、行程和天气；
沿用详情页像素加载效果。已登录指定家庭 NAS 后自动验证展示权限，无需再次
登录网站。此入口仅提供 Home Display 的只读内容，画质随设备能力自适应。

3.0.9：全新影院玻璃图标，程序坞显示完整图标，菜单栏采用随系统配色的原生模板标记。
左上角版本文字保持原样，点击切换整窗半透明；默认不透明度80%，保存的自定义值保留。
修复动漫公开弹幕请求兼容，增加本地番剧名称索引回退，按真实集号匹配；默认显示弹幕，手动关闭设置保留。

3.0.7：首页海报按窗口限高并使用真实横图；详情提供普通海报回退和随海报色彩流动的磨砂背景。
修复 Home Display 授权 Cookie 兼容问题并优化加载、退出与滚动性能。
正式版默认隐藏悬浮导航中的动漫入口，可在设置中重新打开；显示偏好只保存在本机，升级时保留。

3.0.6：首页精选只使用经实际尺寸确认的横版剧照；Home Display 从真实页面预览显影，
去除生成的占位网格，返回时以真实页面像素播放电视机关闭效果，无开灯段。
3.0.5：减少首页滚动时的卡片重复构建；Home Display 渲染观察移出逐帧路径，
加载网格由前台 GPU 独立绘制，仅在关键就绪阶段获取预览，保留网页的高清画质与实时更新。
3.0.4：首页大海报横向贯穿窗口，详情信息下移并配合柔和磨砂暗底，提升文字对比度。
3.0.3：大海报完整保留构图，以边缘延展形成柔和暗场；播放器灯效连续过渡，
详情显影跟随屏幕刷新节奏，减少评分后台更新导致的无关整页重排。
3.0.2：首页精选改用高清图片并按窗口高度扩大，热门、最新与评分统一布局和资源标注；
详情恢复灰黑磨砂渐变，等待高清图片实际解码后收尾。Home Display 顶部透明，
全屏和切换桌面时保留网页，避免重复销毁原生 WebKit。

3.0.17 HomePod：设置 → HomePod 低延迟输出，可将整个 Mac 的声音发送到同一网络的
HomePod。功能默认关闭；先查找并选择扬声器，首次主动开启时按需安装 NAKU 专用
虚拟输出驱动，已有兼容驱动会复用。NAKU 留在后台时继续工作，关闭或退出后恢复原输出。
家庭 App 的扬声器访问需允许同一网络中的设备。连接后可单独调整 HomePod 音量；
发送缓冲目标不等于总声学延迟。本功能不使用系统录音或麦克风接口。

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


def package(app: Path, output: Path, version: str, *, zip_only: bool = False, source_archive: Path | None = None) -> None:
    if sys.platform != "darwin":
        raise ValueError("Packaging requires macOS")
    for tool in ("codesign", "lipo", "otool", "ditto", *(() if zip_only else ("hdiutil",))):
        if shutil.which(tool) is None:
            raise ValueError(f"Required macOS tool is unavailable: {tool}")
    if not app.is_dir() or app.suffix != ".app":
        raise ValueError("--app must point to an existing .app bundle")
    if output == app or output.is_relative_to(app):
        raise ValueError("--output must be outside the app bundle")
    if source_archive is not None and (not source_archive.is_file() or source_archive.suffix != '.zip'):
        raise ValueError("--source-archive must point to an existing source ZIP")
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
        with (app / "Contents/Info.plist").open("rb") as stream:
            minimum = str(plistlib.load(stream)["LSMinimumSystemVersion"])
        instructions = installation_text(version, minimum).replace('当前公开版本', '当前安装包')
        if source_archive is not None:
            shutil.copyfile(source_archive, stage / source_archive.name)
            instructions += f'\n本次交付附对应源码：{source_archive.name}。源码无需安装。\n直连弹幕适配的 LogVar / danmu_api 许可及源文件见该档案中的 licenses/danmu_api。\n'
        guide.write_text(instructions, encoding="utf-8")
        shutil.copyfile(guide, stage / guide.name)
        zip_path = work / filenames[0]
        # No enclosing directory: Sparkle finds the one app at archive root.
        run("ditto", "-c", "-k", "--sequesterRsrc", stage, zip_path)
        dmg_path = work / filenames[1]
        if not zip_only:
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
        if source_archive is not None and sha256(extracted / source_archive.name) != sha256(source_archive):
            raise ValueError("ZIP did not preserve the corresponding source archive")
        artifacts = [zip_path, *([] if zip_only else [dmg_path]), guide]
        manifest = work / "SHA256SUMS"
        manifest.write_text(
            "".join(f"{sha256(path)}  {path.name}\n" for path in artifacts),
            encoding="utf-8",
        )
        # Publish locally only after all checks pass. No partial artifacts are
        # written when signing, architecture, or archive validation fails.
        for artifact in [*artifacts, manifest]:
            artifact.rename(output / artifact.name)
    print("Created " + ", ".join(path.name for path in [*artifacts, manifest]))
    print("The app was not modified or re-signed. Sign the ZIP and appcast before publishing.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True, help="Already signed universal .app bundle")
    parser.add_argument("--output", type=Path, required=True, help="Release artifact directory")
    parser.add_argument("--version", required=True, help="Exact CFBundleShortVersionString, e.g. 1.0.0")
    parser.add_argument("--zip-only", action="store_true", help="Create the verified Sparkle/install ZIP without a DMG (for hosts without disk-image services)")
    parser.add_argument("--source-archive", type=Path, help="Embed this corresponding source ZIP alongside the app in both packages")
    args = parser.parse_args()
    if not re.fullmatch(r"\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?", args.version):
        parser.error("--version must be a dotted semantic version such as 1.0.0")
    try:
        package(args.app.expanduser().resolve(), args.output.expanduser().resolve(), args.version, zip_only=args.zip_only,
                source_archive=args.source_archive.expanduser().resolve() if args.source_archive else None)
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
