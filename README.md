# NAKU播放器

macOS 电影、剧集与动漫播放器。基于 [Kazumi](https://github.com/Predidit/Kazumi) 2.3.8 修改，保留 GPL-3.0 许可证。

[下载最新版本](https://github.com/NakuTop/NAKU-Player/releases/latest) · [更新记录](CHANGELOG.md) · [构建与发布](docs/RELEASING.md) · [双人一起看](docs/WATCH_TOGETHER.md)

## 功能

- 黑橙磨砂玻璃界面，详情页虚化封面背景；全屏内也可切源、选集、收藏、画中画和一起看。
- 电影、剧集、动漫目录，热门 / 最新排序，默认打开已启用的魔都影视；切换栏目保留列表、搜索、分页和滚动位置。
- 多源搜索按作品保守合并；详情展示封面、简介、导演、演员 / 配音、地区、语言和评分。
- 同作品各来源的播放线路集中在播放页。线路失败后尝试能确认同一集的其他线路，保留播放进度；每轮有次数上限。
- 画中画（桌面置顶小窗）、Anime4K 超分辨率、倍速、全屏、选集、收藏及历史续播。
- 收藏和历史按作品跨源合并，观看记录保留最后使用的来源与进度；升级迁移前自动备份。
- 一起看：配对持续保存，离开播放页或重启后可重连；主动跟随同伴当前作品，成功同步后提示对方。通过 TLS Syncplay 房间同步播放 / 暂停 / 进度，不发送媒体地址。
- 豆瓣选电影 / 选剧集列表及官网提供的筛选和排序。匿名接口可能只返回少量内容。
- 豆瓣、IMDb、烂番茄评分摘要与精确条目关联；没有可靠数据时显示暂无评分，片源转录分数有单独标记。
- Bangumi 动漫目录与搜索；无上游签名密钥的构建使用官方公开搜索接口。
- 片源管理、Kazumi XPath 规则、网页影院。
- Sparkle 自动更新：默认定期检查，可在“软件更新”开启自动下载和安装；更新目录与安装包都校验 Ed25519 签名。已发布签名更新目录；也可以从 Releases 下载并手动更新。

## 安装

macOS 12 或更新版本，通用安装包支持 Apple Silicon / Intel。打开 DMG，将 **NAKU播放器.app** 拖入“应用程序”。

当前版本为本地 ad-hoc 签名，未通过 Apple Developer ID 公证。如果 macOS 阻止首次打开，请核对本仓库发布来源与 SHA-256 后，在“系统设置 → 隐私与安全性”使用“仍要打开”。不需要关闭系统安全功能。

从映川升级保留已有片源、收藏、观看记录和评分关联。为兼容旧资料，内部应用标识仍为 `com.shenminghao.yingchuan`。不要同时运行新旧版本。

## 播放与评分

来源由用户配置或公开接口提供，本项目不存储、上传或分发影视文件，不是 Netflix 官方客户端。请依据内容授权使用来源。接口返回成功不等于影片可播放，画质标签不等于媒体实际分辨率。

跨源自动接续要求保守的作品与集数匹配；不同季、年份、同名歧义、缺少足够身份信息时保留手动选择。各站剪辑和片头可能不同，换源后可手动调整进度。

超分辨率使用随上游提供的 Anime4K 着色器，适合动画，不会让原始片源变成真正的高分辨率母版。一起看需要双方网络能访问同一个 Syncplay 服务器，且各自具有可播放的对应影片。

IMDb 数据来自官方个人非商业数据集；豆瓣、烂番茄读取公开条目。评分、海报、演职员资料及榜单归相应权利人所有，遵循各数据源条款。未提供资料时不会生成或猜测演员、评分。

## 开发

使用 Flutter 3.47.6 / Dart 3.13.5、Xcode、CocoaPods；锁定 macOS Sparkle 2.9.6。Dart 包名保留 `kazumi` 以兼容上游模块。

```sh
flutter pub get
cd macos && pod install && cd ..
flutter test --no-pub test/features/cinema test/bangumi_search_request_test.dart
flutter build macos --release --no-pub
```

真实网络测试单独启用，不与 widget HTTP mock 混用：

```sh
NAKU_LIVE_TESTS=1 flutter test --no-pub test/features/cinema/douban_live_test.dart
```

## 来源与许可证

- 基础：[Predidit/Kazumi](https://github.com/Predidit/Kazumi)，GPL-3.0，基准提交 `11671bc0ec61727e99e34810f142a1b5e4121a8e`。上游 README 保留于 `docs/UPSTREAM_README.md`。
- 网页影院参考：[Joyflix-Mac-Objective-C](https://github.com/jeffernn/Joyflix-Mac-Objective-C)，Apache-2.0；具体引用说明与许可证位于 `licenses/`。
- 更新：[Sparkle](https://sparkle-project.org/)，许可证位于 `licenses/Sparkle-LICENSE.txt`。
- 播放与着色器使用上游保留的 media-kit、mpv、Anime4K 等组件与许可证。

完整修改源码随版本公开，详见 [LICENSE](LICENSE)。
