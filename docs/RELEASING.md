# 构建、签名与发布

发布仓库：`NakuTop/NAKU-Player`。更新 Feed：
`https://raw.githubusercontent.com/NakuTop/NAKU-Player/main/appcast.xml`。

## 版本与构建

以下以 `1.0.0+7` 为例。构建号必须大于上一版本；包版本、Git tag、更新目录和发布说明必须一致。先更新 `pubspec.yaml`、CHANGELOG 与版本相关资料，再运行仓库约定的检查：

```sh
flutter pub get
(cd macos && pod install)
flutter test --no-pub test/features/cinema test/bangumi_search_request_test.dart
flutter analyze --no-pub lib/features/cinema test/features/cinema
flutter build macos --release --no-pub
```

使用仓库指定的 Flutter / Dart、Xcode 和已提交的 `macos/Podfile.lock`。网络测试单独启用，并区分接口访问、实际视频播放、双方同步和更新安装链路的验收结果。不要把本地两客户端测试表述为已通过真实跨国网络验收。

## 代码签名与打包

构建完成后，先完成应用及嵌套框架、Sparkle XPC 服务和辅助程序的代码签名。签名时保留应用所需的 App Sandbox、网络和 Sparkle mach-lookup entitlements；不要用 `codesign --deep --sign` 代替逐层签名。正式使用 Developer ID 时，再完成 Apple 公证与 stapling，然后打包。

`package_macos.py` **只校验和打包，不重签应用、不访问钥匙串、不发布文件**。它检查版本与全部 Mach-O 的 Apple Silicon / Intel 架构，包含主程序、App、FlutterMacOS、Sparkle 及其辅助程序；校验原始应用、复制后的应用以及解压 ZIP 后的严格代码签名，并执行 `hdiutil verify`。校验失败即停止，不通过重签掩盖问题。

在仓库根目录执行，输出目录可自行指定：

```sh
python3 scripts/package_macos.py --help
python3 -m py_compile scripts/package_macos.py
python3 scripts/package_macos.py \
  --app build/macos/Build/Products/Release/NAKUPlayer.app \
  --output artifacts/1.0.0 \
  --version 1.0.0
(cd artifacts/1.0.0 && shasum -a 256 -c SHA256SUMS)
```

输出：

- `NAKUPlayer-1.0.0-macOS-universal.zip`：Sparkle 更新归档，同时可手动解压安装。
- `NAKUPlayer-1.0.0-macOS-universal.dmg`：常规下载安装包。
- `INSTALL-zh-CN.txt`：简短安装和一起看说明。
- `SHA256SUMS`：上述文件的 SHA-256。

两个归档均包含展示名为 `NAKU播放器.app` 的应用、`Applications` 链接和安装说明。脚本拒绝覆盖已有同名成品；重新打包时请使用新目录或明确移走旧文件。打包不包含工作区路径、用户数据、发布私钥或本机配置。

本地 ad-hoc 代码签名不等于 Developer ID 签名或 Apple 公证。默认安装说明准确标明当前 ad-hoc 状态；未来切换到公证发行时，发布者须同步更新安装说明。Sparkle 的发布签名用来验证更新的发布者和内容，不能替代 Apple 公证。

## Sparkle 更新签名

从 [Sparkle 官方发行页](https://github.com/sparkle-project/Sparkle/releases) 获取签名工具。当前签名工具为 2.10.0，应用运行时 CocoaPods 锁定 2.9.6；使用 Ed25519 更新签名。私钥仅保留在发布机器的 macOS 登录钥匙串，account 为 `NakuTop.NAKUPlayer`。不要导出到源码、日志或 Release，也不要为常规升级生成替代密钥。应用 `Info.plist` 中的 `SUPublicEDKey` 必须对应这个 account。

设置实际工具目录，然后签署最终 ZIP：

```sh
NAKU_SPARKLE_BIN=/path/to/Sparkle/bin
"$NAKU_SPARKLE_BIN/sign_update" --account NakuTop.NAKUPlayer \
  artifacts/1.0.0/NAKUPlayer-1.0.0-macOS-universal.zip
```

工具返回可公开的 `sparkle:edSignature` 和 `length`。将其原样填入下列模板，替换占位值；`sparkle:version` 为构建号，`sparkle:shortVersionString` 为用户可见版本号。ZIP URL 必须指向已经存在且可匿名下载的正式 Release 资产。

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>NAKU播放器</title>
    <link>https://github.com/NakuTop/NAKU-Player</link>
    <description>NAKU播放器 macOS 更新</description>
    <item>
      <title>NAKU播放器 1.0.0</title>
      <sparkle:version>7</sparkle:version>
      <sparkle:shortVersionString>1.0.0</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>12.0.0</sparkle:minimumSystemVersion>
      <description><![CDATA[此处填写本版本更新说明。]]></description>
      <enclosure
        url="https://github.com/NakuTop/NAKU-Player/releases/download/v1.0.0/NAKUPlayer-1.0.0-macOS-universal.zip"
        length="REPLACE_WITH_EXACT_BYTE_LENGTH"
        type="application/octet-stream"
        sparkle:edSignature="REPLACE_WITH_ARCHIVE_SIGNATURE" />
    </item>
  </channel>
</rss>
```

先验证 ZIP 签名，再为最终 XML 嵌入签名。以下 `ARCHIVE_SIGNATURE` 是上一步的公开签名，不是私钥：

```sh
"$NAKU_SPARKLE_BIN/sign_update" --account NakuTop.NAKUPlayer --verify \
  artifacts/1.0.0/NAKUPlayer-1.0.0-macOS-universal.zip 'ARCHIVE_SIGNATURE'
"$NAKU_SPARKLE_BIN/sign_update" --account NakuTop.NAKUPlayer appcast.xml
"$NAKU_SPARKLE_BIN/sign_update" --account NakuTop.NAKUPlayer --verify appcast.xml
```

签署 XML 后不要格式化、改变换行或修改内容。任何后续修改都必须重新签署并验证。应用开启 `SURequireSignedFeed` 与更新归档签名验证，必须同时发布正确签名的 Feed 和 ZIP。不要将归档签名错填为 XML 签名，也不要把 DMG 的签名填入 ZIP enclosure。

## GitHub 与安装验收

1. 审阅并提交最终源码，创建 `v1.0.0` tag，确保它对应实际构建来源，保留 GPL 和所有依赖许可证。源码中不得包含私人凭据或用户观看记录。
2. 导出该 tag 的源码 ZIP，把源码 ZIP 的 SHA-256 加入 `SHA256SUMS`，然后再次验证所有条目。例如：

   ```sh
   git archive --format=zip --prefix=NAKU-Player-1.0.0/ v1.0.0 \
     > artifacts/1.0.0/NAKU-Player-1.0.0-source.zip
   (cd artifacts/1.0.0 && shasum -a 256 NAKU-Player-1.0.0-source.zip >> SHA256SUMS)
   (cd artifacts/1.0.0 && shasum -a 256 -c SHA256SUMS)
   ```

3. 发布非草稿、非预发布的 GitHub Release，上传 ZIP、DMG、源码 ZIP、安装说明与校验清单。不要覆盖已发布的同版本归档；修复应递增版本和构建号。
4. 在未携带 GitHub 身份凭据的请求中下载正式资产，核对字节长度和 SHA-256。带认证的 `gh` 元数据查询不能替代匿名资产下载验证。
5. 资产可访问后提交已签名的 `appcast.xml` 到 `main`，从实际 Feed URL 下载，再验证 XML 签名。
6. 用前一构建实际执行“软件更新 → 检查更新 → 安装”，验证应用重启、版本和用户片源 / 收藏 / 历史保留，再检查最新版状态。仅看到“已经是最新版”不构成完整升级验收。

原 Kazumi 的多平台发布工作流保留在 `docs/` 文本归档中，不在本仓库自动执行。独立仓库不需要、也不包含上游 Bangumi 镜像或弹幕私钥。

## 本机应用副本清理

日常使用只保留 `/Applications/NAKU播放器.app`。构建和升级验证产生的 `.app` 会被 Spotlight / Launch Services 识别，不能把历史副本直接留作备份。验证后应先用 `ditto` 压缩归档、解压逐文件校验，确认没有进程使用旧路径，再按旧路径注销 Launch Services 并移除已归档的展开副本。备份 ZIP 放在 `.noindex` 目录；不得删除用户的片源、收藏、历史或签名钥匙。

验收鼠标问题时必须包含实际鼠标点击，AX 语义按钮调用成功不能替代鼠标命中测试。自动化工具无法发送有效坐标点击时，应记录限制并让用户测试已安装的具体版本。
