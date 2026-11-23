# 安卓差分更新

手机和电视从 3.2.20 起支持差分。旧客户端读取原有入口，首次通过完整 APK 升级。手机与电视使用各自的应用签名校验和更新源，用户在 Android 系统安装器中确认覆盖安装。

## 正式发布

以现有签名构建两个通用 APK，并分别发布到 `v<版本>-android` 和 `android-tv-v<版本>+<构建号>`。各发布页保留完整 APK。正式发布事件会运行 GitHub Actions 的 **Publish Android differential updates**，更新应用内清单。

每次发布为至多三个最近的正式基础版本生成单跳补丁。发布工具用客户端实际使用的解码器还原 APK，逐字节对照已签名正式包，并核对公开补丁的 SHA-256 和大小后更新清单。手机读取 `android-update.json`，电视读取 `android-tv-update.json`。两端均检查基础版本和安装包摘要，损坏或不适用的补丁自动回退到完整 APK。

任务中断可对同一标签重新运行工作流，也可以运行以下命令。需要 Python 3.11 以上、JDK 17 以上、Android SDK Build Tools 和拥有该仓库发布权限的 GitHub CLI。命令复用已验证的公开资源。

```sh
python3 scripts/publish_android_deltas.py --tag v3.2.20-android
python3 scripts/publish_android_deltas.py --tag android-tv-v3.2.20+148
```
