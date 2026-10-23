# 自动字幕与影视弹幕（macOS 2.11.1）

播放页的「字幕与音轨」按字幕、音轨、显示分组。字幕页优先显示当前文件、自动对齐和提前/延后0.5秒；下面直接浏览、搜索对白并选句对齐当前画面。慢速回听和双点漂移位于「精细校准与慢速回听」，文件选择、自动字幕和整季下载设置放在后方。

## 自动字幕

1. 先恢复同视频保存的字幕、手动轨道或关闭选择，保留已有校准。
2. 优先选择可显示的内置中文字幕，避免重复加载。图片字幕在后端无法显示时不会被误认为可用文本字幕。
3. 无独立轨道时，macOS Vision 辅助检查当前画面下方的中文字幕；三个画面至少两个识别到中文才保守跳过在线加载。此检测不能保证发现所有烧录字幕，片头、暂停画面或片内文字也可能影响判断，可手动搜索或关闭外挂字幕。
4. 缺字幕时，以公开片名、季和集聚合搜索经校验的文件，中文优先。找不到匹配中文时才尝试英文。手动操作和退出视频会取消旧请求，不将 NAS 播放地址发给字幕目录。
5. 加载未校准的新外挂字幕后尝试本地校准。默认只分析一段5秒音频，可在字幕对齐区把「采样时长」拖动到5–20秒，按1秒递增并记住选择。自动选择附近对白较密集的片段，独立解码16kHz单声道音频，不改变主播放器的进度、暂停或倍速。

macOS 26及支持SpeechTranscriber的设备使用系统本地语音识别，将对白文字与字幕做序列匹配；首次使用某种语言可能需要系统下载本地模型。结合WebRTC VAD修正识别结果把前置停顿算入句首词的问题。只有唯一且足够可信的对白才应用偏移，保留已有时间轴倍率。重复短句、纯音乐、识别语言和字幕不一致时保留原校准，提示换有对白的位置、加长采样或选句手动对齐。双语字幕可用原声语言直接匹配；外语原声只有中文译文时，不能保证直接按文字匹配。

macOS 13–25及不支持本地语音模型的设备保留短片VAD/选句起点校准与手动校准。选中听到的字幕后可用「按这句自动对齐」，或直接把该句对齐当前画面；精细回听及双点漂移校准保留在后方。没有实时字幕生成功能，不录制麦克风，不调用外部AI API。

自动对齐显示读取、识别、匹配和保存阶段，提供已用时间与取消按钮；默认5秒采样的整体时限为30秒，20秒采样为45秒。超时、取消和失败会结束加载，迟到结果不能覆盖新字幕或手动校准。应用但保存未完成时明确提示，只有完成保存才显示保存成功。最近4段音频及识别文字保留在当前会话中，复用附近有效对白，退出视频后释放。

字幕文件缓存最多64个视频、32 MiB，每个文件4 MiB；只存本机，不进入片库导出。支持 SRT、ASS/SSA、VTT 和 HTTPS 字幕链接。

## 整季字幕缓存

加载、导入或恢复一集外挂字幕后，按当前播放列表中的季/集逐集匹配并下载，优先下一集，然后检查本季前面各集。选择来自整季压缩包的字幕时，先复用该包并列出其他字幕文件，不为每集重新检索全部网站；逐个检查实际文件名、季/集及对白语言。其他情况在找到首个可用文件后即可结束该集的后台搜索，避免被失效来源长期拖住。请求仅使用公开片名、IMDb和季/集，不上传NAS路径。队列一次处理一集，切换视频仍可继续；应用退出后停止，重开视频会检查已有缓存并补齐。切入尚未缓存的集数会将该集提到队列前方，并最多等待12秒共享后台结果，再回退到本集搜索；不会载入上一集的字幕。没有公开匹配、字幕源失效或播放列表尚未列出的剧集不能提前下载；失败项在进入后续集数时重试，也可在「自动字幕与整季下载」中重试。

缓存按作品、季、集和所选字幕版本隔离，位于本地字幕缓存的season-v1目录，最多512项/128MiB、每项4MiB；不进入片库导出。同版本字幕在加载时读取最新的整季校准，不会因提前下载而使用旧偏移；不匹配的剪辑版本保留独立时间轴，并按原规则尝试本地对齐。已手动关闭的本视频、已保存的本集校准优先；在线搜索取消勾选整季下载后会记住仅本集选择。

## 长按快捷键

左右键短按按原跳转秒数执行。长按400毫秒后，右键使用临时倍速（默认2倍，可沿用设置中的自定义值），左键按约2倍速连续回退；回退通过约100毫秒一次的定位实现，不是反向逐帧解码。松开后恢复原来的倍速及播放/暂停；失焦、切换集数和退出也会释放临时状态。不依赖macOS按键自动重复，编辑字幕搜索框和调节控件时保留控件自身的方向键行为。

## 影视弹幕

电影和剧集由播放器直接获取平台弹幕，无需NAS、UGlink、服务地址、访问令牌或弹弹play凭据。使用公开片名、年份、季和集核对目录，再请求优酷、腾讯、爱奇艺、芒果和Bilibili的对应视频弹幕。不会将NAS播放URL、路径、NAS登录凭据或本机浏览器Cookie交给平台；同名翻拍、季数冲突、预告及重复的系列首页链接不会被自动当作正片分集。

弹幕按钮只保留显示开关、字号、不透明度、显示区域和滚动时长。开关和样式跨集记忆，关闭时停止网络加载。切集、关闭和手动替换会取消旧请求，旧集迟到的结果不能进入新集。缓存仍按具体视频隔离。

按当前播放位置获取前30秒至后约150秒的分片，播放时提前补充，拖动后转到对应时段。最近只保留6个分片，每片最多2000条，当前显示窗口最多6000条；高密度分片保留均匀分布，避免把限额全部用在片头。Bilibili分片API受限时，回退到最多4MiB的压缩XML缓存，在隔离线程里流式解压和筛选当前窗口，不展开保存整集弹幕对象。解压读取有32MiB上限。退出视频清空弹幕对象、分片及压缩缓存。数据文件仍受32视频/64MiB的全局上限约束。256MB视频预读设置独立保留。

分片并发最多3个，单个响应最多2MiB，失败分片重试一次；部分缺失会明确标注。播放中的分片失败在短暂退避后自动重试，优酷匿名会话过期会刷新并重试，不要求用户填写Cookie。平台没有该影片或暂时限制访问时，不保证每部影片都有弹幕。新设备直接使用该流程，NAS账号不参与弹幕认证。

动漫模块原有弹弹play可选配置保留；影视默认直连不使用弹弹play或第三方公共弹幕代理。适配参考[LogVar / danmu_api](https://github.com/huangxd-/danmu_api)，对应许可见`licenses/danmu_api`，本次个人交付附源码快照。

## 自动分流与缓存

macOS默认启用影视自动分流，使用本机已有的HTTP/HTTPS代理配置，对公网媒体做有界直连/代理比较；没有可用代理时直接连接。每条路径最多读256KiB、总比较最多6秒，决策按CDN和代理配置缓存10分钟。播放列表与实际视频分别判断，小于32KiB的初始化片段不建立视频CDN决策。局域网和NAS播放不参与公网比较。代理连接失败尝试直连，直连失败尝试代理；实际下载持续变慢或播放缓冲后可重新判断。关闭磁盘缓存仍可使用HLS自动分流，此时仅转发请求，不写入媒体片段。设置 → 网络代理可关闭自动模式并恢复手动控制。

所选256MB为向前缓存目标，另有最多16MB的回看保留；暂停和播放中均持续读取，直到字节上限、片尾或片源停止供给。缓存用量、可播放秒数与连接路径每秒刷新，倍速下按真实可播放时间显示。片源本身限速时，预读容量不能提高它的供给速度，自动分流和已有同集换源恢复共同处理这类问题。

本次个人安装包通过NAKU_OPTIMIZE_PLAYBACK_ONCE构建开关，仅在新版本首次启动应用256MB、自动分流和不主动降低前读容量的设置；之后保留用户调整。

## 验证

- `flutter test integration_test/keyboard_transport_test.dart -d macos --dart-define=SUBTITLE_NATIVE_FIXTURES=<sandbox-fixtures>`：使用自写音频验证实际MPV临时倍速、连续回退和松开恢复。
- `flutter test --dart-define=NAKU_SEASON_SUBTITLE_LIVE=true test/features/cinema/cinema_season_subtitle_live_test.dart`：真实整季字幕包下载、全部集数缓存及下一集离线恢复。
- `flutter test integration_test/buffering_pipeline_test.dart -d macos --dart-define=NAKU_BUFFER_NATIVE_FIXTURES=<sandbox-fixtures>`：真实HLS暂停预读、原生缓存计数及播放中持续补充。
- `flutter test`：回归、字幕优先级/关闭/恢复/取消、校准置信度、弹幕时钟、官方目录及跳转、紧凑界面。
- `python3 scripts/test_subtitle_tools_native.py --output <scratch>`：本机生成自写语音，验证实际 WebRTC VAD 和 Vision。
- `flutter test --dart-define=SUBTITLE_VOICE_FIXTURE=<scratch>/voice-fixture.json test/features/cinema/cinema_subtitle_auto_sync_test.dart`：以真实 VAD 输出验证对齐。
- `flutter test integration_test/subtitle_pipeline_test.dart -d macos --dart-define=SUBTITLE_NATIVE_FIXTURES=<sandbox-fixtures>`：将自写 `dialogue.wav`、`cues.json` 放在应用沙箱 tmp 的独立测试目录，验证 Flutter/MPV/Swift 完整音频分析流程。无需关闭沙箱。
- `flutter test --dart-define=NAKU_DIRECT_DANMAKU_LIVE=true test/features/cinema/cinema_direct_danmaku_live_test.dart`：直连真实电影、两集剧集及各平台分片，验证跳转补载；测试代理可单独传`NAKU_TEST_PROXY`。
- `flutter test integration_test/direct_danmaku_pipeline_test.dart -d macos --dart-define=NAKU_DIRECT_NATIVE_FIXTURES=<isolated-fixtures>`：使用独立片库验证真实平台弹幕、MPV时钟、Canvas、切集、跳转和关闭恢复，不读NAS凭据。
- `flutter test integration_test/subtitle_word_pipeline_test.dart -d macos --dart-define=NAKU_WORD_NATIVE_FIXTURES=<isolated-fixtures>`：自写对白验证5秒及20秒音频提取、本地文字识别、偏移保存及主播放状态。

## 参考

- [ffsubsync 的区间匹配原理](https://ffsubsync.readthedocs.io/en/latest/how_it_works.html)
- [libfvad](https://github.com/dpirch/libfvad)，固定提交见 `third_party/libfvad/NAKU.md`
- [LogVar / danmu_api](https://github.com/huangxd-/danmu_api)
- [Apple SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber)
- [弹弹play接入指南](https://doc.dandanplay.com/open/)
- [项目分层与配额](https://dev.dandanplay.com/PublicPage/Quota)
- [官方 Swagger](https://api.dandanplay.net/swagger/index.html)
