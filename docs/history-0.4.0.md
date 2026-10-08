# 映川 · 个人影院 0.4.0

基于 [Predidit/Kazumi](https://github.com/Predidit/Kazumi) 2.3.8（commit `11671bc0ec61727e99e34810f142a1b5e4121a8e`）的个人修改版，保留 GPL-3.0。macOS 应用标识为 `com.shenminghao.yingchuan`；Dart 包名继续使用 `kazumi` 以兼容上游模块。

本说明依据 0.4.0 代码与已记录的来源研究编写。实际安装、界面操作、声音和连续播放验收，以随附 `验证记录-0.4.0.json` 为准；本文不将接口返回、自动测试或无窗口短解码当成应用内播放验收。

## 功能

- 电影、剧集、动漫独立目录；MacCMS V10 分类、搜索、分页、海报、详情与播放线路。
- Kazumi XPath 动漫搜索和选集，保留原 Bangumi 动漫目录。
- media_kit 原生播放、换线、选集、倍速、全屏与续播；收藏和历史按片源、作品保存。
- 影视接口添加、编辑、启停、移除；动漫规则 JSON 导入和编辑。
- “网页影院”保留 Joyflix 的 9 个原始网页入口，加上用户提供的网站，支持分类、站点管理、首页响应检查和恢复上次入口。
- 电影、剧集各自可选“最新/热门”，仅排序当前页；所有个人影院海报卡显示豆瓣、IMDb、烂番茄评分摘要，详情可查看来源和手动关联。
- 目录优先打开已启用的魔都；搜索中的同一作品保守合并为一张卡片，进入详情后选择片源与语言版本。
- 读取 macOS HTTP/HTTPS 系统代理，不改变系统代理，不关闭 TLS 验证；原接口和原生播放暂不支持 PAC 自动脚本。禁用上游应用更新，避免官方安装包覆盖个人功能。

## 0.4.0 默认来源

保留 **7 个 MacCMS 接口 + 3 个动漫规则**。目录未选择片源时，优先使用已启用的魔都；魔都不存在或已停用时，使用其他已启用影视接口。你仍可在上方切换片源，此偏好不会重排或覆盖已保存的片源配置。

下表沿用预设清单顺序。尺寸和时长均属于已检查的具体短样本，不能推广为全站或整片质量保证。

| 影视接口 | 原始 URL | 已记录的边界 |
| --- | --- | --- |
| 光速影视 | `https://api.guangsuapi.com/api.php/provide/vod/` | 保留原接口；曾有《星际穿越》1920×808短解码，也有其他影片分片失效。 |
| 魔都影视 | `https://www.mdzyapi.com/api.php/provide/vod/` | 电影短样本1920×1080、约171分钟。 |
| 豪华影视 | `https://hhzyapi.com/api.php/provide/vod/` | 电影短样本1920×808、约169分钟。 |
| 无尽影视 | `https://api.wujinapi.me/api.php/provide/vod/` | 保留原 `.me` 地址；既有电影样本出现约85分钟的时间轴异常。 |
| 极速影视（0.3.0加入） | `https://jszyapi.com/api.php/provide/vod/` | 《星际穿越(原声版)》短解码1920×808，媒体报告约169.07分钟。 |
| 如意影视（0.3.0加入） | `https://cj.rycjapi.com/api.php/provide/vod` | 《星际穿越》短解码1920×808，媒体报告约169.94分钟。 |
| 360影视（0.3.0加入） | `https://360zy.com/api.php/provide/vod` | 《怪奇物语第五季》第1集短解码1920×1080、约72.35分钟；不能据此保证电影高清。 |

动漫预设为 DM84、MXdm（v2.4）、moonci，来自 [KazumiRules](https://github.com/Predidit/KazumiRules)。

此前另一个 360 API 入口 `360zyzz.com` 的《星际穿越》样本仅为720×406。该历史结果与本次 `360zy.com` 的1080p剧集样本分别记录：端点、作品不同，不能互相替代或推断所有内容高清。

用户提供的8个候选 API 的原地址、字段和媒体记录见 `API候选核查-2026-10-08.txt/.json`。其中天涯不支持本次 `wd` 搜索，卧龙返回域名出售页；无尽 `.com` 的目录可读，但电影样本本次未通过媒体 TLS 握手，不能当作既有 `.me` 的同一条验证记录。极速、如意、360已在0.3.0加入，0.4.0继续保留。更多历史比较见 `第三方片源核查报告-2026-10-08.txt` 和 `片源实测证据.json`。

## 已安装用户的资料升级

0.4.0沿用已有资料，不因默认魔都或搜索合并而改写片源顺序、收藏和历史。尚未升级过0.3.0来源包的旧资料，会先通过完整校验，保存一次原始备份 `library-v1.json.pre-0.3.0.bak`，再补入缺少的来源；已完成升级的资料不会重复补源。

- 保留原片源名称、地址、启用状态、请求头、收藏和历史；不会用默认配置覆盖用户设置。
- 同 ID 或规范化 URL 已存在时跳过新增；既有 `.me` 不替换为 `.com`。
- 升级幂等，用户删除新增源后不会在下次启动恢复。已有备份不覆盖；损坏资料保持原样并显示错误。

本机 macOS 沙盒资料目录：

```text
~/Library/Containers/com.shenminghao.yingchuan/Data/Library/Application Support/com.shenminghao.yingchuan/cinema/
```

该目录内 `library-v1.json` 保存原接口、收藏与历史；升级备份为同目录 `library-v1.json.pre-0.3.0.bak`。网页站点另存 `websites-v1.json`；评分关联和缓存位于 `ratings/`，不与上游 Kazumi 数据混用。

## 搜索合并与详情切源

输入片名搜索后，同一作品尽量合并为一张卡片，并显示“几个片源版本”。点击卡片，在详情的“选择片源”中切换；线路、集数和作品资料会重新读取所选片源。普通话、国语、英语或原声等语言版本可以保留在同一卡片内，播放前应核对版本和集数。组内有魔都时，优先用魔都展示卡片。

合并保持保守：相同豆瓣 ID 也要求片名、年份和类型不冲突；没有共同 ID 时，须规范片名相同、年份相同且同类。不同非空豆瓣 ID、不同年份或不同季不会合并；信息不足时可能仍显示多张卡片。中文“一至九十九季”和对应数字季号可识别为同季，剧集“2022–”按起始年2022核对。搜索合并只整理结果，收藏和历史仍按各片源作品保存。

## 当前页“最新/热门”

电影和剧集的目录各自选择排序方式，搜索结果不显示该排序控件。当前页按 `vod_time`（片源更新时间）或 `vod_hits`（片源自报热度）降序排列；缺失值排后，相同值保留原顺序，全部缺失时保持片源顺序。

这不是上映日期榜，也不是全库或全网热门榜。换页后仅排列新的一页；没有跨页抓取或全库聚合。来源研究中的 `sort=score`、`sort=hits` 未显示改变接口返回顺序，因此此功能在本地对当前页排序，不宣称来源支持这些远程参数。第三方热度字段有大量0值及统计口径不一致的情况。

## 作品评分与条目关联

个人影院的所有海报卡都显示豆瓣、IMDb、烂番茄摘要；豆瓣与 IMDb 为10分制，烂番茄为百分比，缺值显示 `—`。豆瓣分数后的 `*` 表示片源转述，鼠标悬停可看未核验说明。点击整张卡片仍进入详情，可查看评分来源和关联条目。

有确切条目 ID 的卡片会在后台逐项查询，并与详情共用评分缓存。离开页面后，尚未开始的卡片请求会取消；已经发出的请求可能继续完成。缺少确切 ID 或服务暂不可用时，未取到的分值保持 `—`；已有片源豆瓣转述分数仍带 `*` 显示，不会仅凭片名猜分。

- **豆瓣**：按精确 subject ID 读取官网公开条目。官网未返回评分时，只有未改为其他豆瓣条目的情况下，才可回退到片源的 `vod_douban_score`，明确标注“片源转述 · 未核验”。不把片源自有 `vod_score` 冒充豆瓣评分。
- **IMDb**：首次需要时按需下载约9 MB的[官方每日评分数据集](https://data.imdb.com/non-commercial-datasets/)，用精确 `tt` ID 查询 `averageRating` 和 `numVotes`。下载文件只作个人非商业本地缓存，不随源码或安装包再分发；使用范围见 [IMDb 官方说明](https://help.imdb.com/article/imdb/general-information/can-i-use-imdb-data-in-my-software/G5JTRESSHJBBHTGX)。
- **烂番茄**：尽力读取精确官网条目中明确命名的 **Tomatometer**，显示影评人好评百分比。**Popcornmeter** 是观众好评百分比，本版不拿它填补影评人分数，也不把百分比换成平均星级。[官方定义](https://www.rottentomatoes.com/about)

缺少 IMDb/烂番茄 ID 时，程序可按豆瓣 ID 精确查询 Wikidata 的 [P4529](https://www.wikidata.org/wiki/Property:P4529)，要求唯一实体，并核对片名、年份与条目类型信息，再读取 IMDb P345 / 烂番茄 P1258。季度条目需手动确认，避免把整剧评分当作本季评分；匹配冲突或无法核验时提示关联，不靠模糊片名猜分。

点击“关联条目”可填写或清空豆瓣、IMDb、烂番茄三个 ID，核对片名、年份、季数后“确认并保存”；“刷新评分”强制重新查询。正常成功评分缓存24小时，未取到评分的结果缓存30分钟，跨站映射缓存7天；IMDb数据通常24小时复用，主动刷新可能重新下载。缓存文件为 `cinema/ratings/ratings-v1.json` 和 `cinema/ratings/title.ratings.tsv.gz`。

本实现不要求填写 API key。公开页面和映射服务仍可能限流、验证或缺少条目；评分不可用不改变片源或播放状态。详细使用方式见随附 `评分与排序说明-0.4.0.txt`。

Information courtesy of IMDb (https://www.imdb.com). Used with permission.

## 网页影院：参考 Joyflix

参考 [Joyflix 固定提交](https://github.com/jeffernn/Joyflix-Mac-Objective-C/commit/96cf8e7ee57a57da8b2f906935bd714398c659de) 的内置网站与 WKWebView 方式，保留9个原网址并加入用户网站。列表可按影视/动漫/直播筛选，支持增删改、首页测速和恢复上次站点；进入后使用网站自己的搜索、选集和 HTML5 播放器。

Joyflix 的这些入口是完整网页，所参考代码未发现统一电影 API。首页 HTTP 响应或响应速度不证明影片可播、清晰度、完整性或口碑。网页书签与原接口资料分开保存，站内收藏/播放进度不自动合并为原接口的收藏和继续观看。来源与一次性首页检测见 `Joyflix参考与站点核查.txt` / `Joyflix站点核查证据.json`。

## 内容与验证边界

“HD/1080P”等标签来自片源；实际解码尺寸和几秒短样本不能证明母版质量或整片完整性。第三方目录中的 Netflix 分类不等于 Netflix 官方媒体 API。本版没有 DRM 解密，也不保证特定 Netflix 节目、院线新片或4K内容。个人影院原生播放器不提供弹幕；上游部分服务需要私有应用密钥，本版没有这些密钥。

本文说明0.4.0的功能和来源边界。安装、实际界面操作及播放检查以 `验证记录-0.4.0.json` 为准，旧版安装和短样本研究不代替本版验收。

## 构建与许可证

需要 macOS 12+、Xcode、Flutter **3.47.6**、CocoaPods、CMake 和 Ninja。保留 `pubspec.lock`。

```sh
flutter pub get
flutter analyze --no-fatal-infos --fatal-warnings
flutter test
flutter test --dart-define=CINEMA_LIVE_TEST=true test/features/cinema/cinema_live_smoke_test.dart
flutter build macos --release
```

联网目录测试不替代播放验收。构建产物位于 `build/macos/Build/Products/Release/YingChuan.app`。重新生成应用图标：

```sh
swift scripts/generate_cinema_icon.swift macos/Runner/Assets.xcassets/AppIcon.appiconset
```

本修改版按 GPL-3.0 提供，保留 `LICENSE`、上游原说明和第三方许可证。Joyflix 参考及 Apache-2.0 文本保留在 `licenses/Joyflix-REFERENCE.txt`、`licenses/Joyflix-Apache-2.0.txt`；IMDb 下载数据适用其自己的使用条件，不因应用源码开源而变成可自由再分发数据。第三方影视目录最初线索来自 [MoonTvConfig](https://github.com/hailowell/MoonTvConfig/blob/main/LunaTv-config.json)，实际核查以记录中的原始 API 请求和样本为准。
