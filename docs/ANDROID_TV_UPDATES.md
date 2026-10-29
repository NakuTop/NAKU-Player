# NAKU TV 软件内更新

TV 使用独立包名 `com.nakutop.nakuplayer.tv`、独立版本号和 TV 发布通道。入口在“我的 → 软件更新”。页面直接检查、下载、校验和启动系统安装器，不依赖电视浏览器。更新覆盖安装保留原应用的 NAS 登录、收藏和历史记录。

- 当前版本从 Android PackageManager 读取，不能使用手机或 macOS 版本判断 TV 是否需要更新。
- 首选 `https://raw.githubusercontent.com/NakuTop/NAKU-Player/main/android-tv-update.json` 静态发布记录；请求失败才回退到官方 GitHub Releases 列表。
- 仅接受 `android-tv-vX.Y.Z+BUILD` 正式标签和 `NAKU-TV-X.Y.Z-Android-universal.apk`。版本号不可倒退，Android build 必须递增；手机、macOS、草稿、预发布和重复资产都不会被选中。
- 发布记录提供精确长度和 SHA-256。下载落在应用私有 cache/naku-tv-updates，取消和失败清除本次临时文件。重试从头下载，不复用未经校验的部分数据。
- 安装前原生桥再次校验 SHA-256、长度、包名、版本、build 和当前安装应用的签名证书，FileProvider 仅共享更新目录内的本次 APK。Android 负责最终安装确认。
- Android 8 及以上首次需要用户允许本应用安装未知来源；从系统设置返回后继续安装已验证的 APK，无需再次下载。

## 准备发布文件

使用相同正式签名构建新包后：

```sh
python3 scripts/prepare_android_tv_update.py \
  --apk build/app/outputs/flutter-apk/app-release.apk \
  --version 1.1.3 --build 5 \
  --output /absolute/path/to/tv-release \
  --build-tools "$ANDROID_HOME/build-tools/36.0.0" \
  --notes-file /absolute/path/to/release-notes.txt
```

该脚本验证签名、TV 包名/启动入口和版本，生成正确命名的 APK、SHA256SUMS 和 android-tv-update.json，**不会上传或发布**。

在用户完成手动验收并明确同意发布后，创建对应正式 GitHub Release，将生成的 APK 和 SHA256SUMS 上传到严格匹配的 TV 标签；再将生成的 `android-tv-update.json` 更新到官方仓库 main 根目录。先确认公开 APK 可下载，再启用静态发布记录。GitHub API 的资产 digest 可作为静态记录外的第二读取路径。

当前正式版本为 `1.1.3+5`，对应标签 `android-tv-v1.1.3+5`。正式安装包、源码快照和校验记录可在 [GitHub Release](https://github.com/NakuTop/NAKU-Player/releases/tag/android-tv-v1.1.3%2B5) 获取；main 根目录的独立 TV 更新记录用于“我的 → 软件更新”。实际电视的系统安装授权与覆盖安装仍需真机验收。
