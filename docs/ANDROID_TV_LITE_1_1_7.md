# NAKU TV Lite 1.1.7（9）

面向用户提供的华为智慧屏 HEGE-570（V75）整理色彩兼容链路；继续使用原生 Media3 1.11.1、硬件 MediaCodec、SurfaceView 与 AudioTrack。保留纯黑、MiSans、海报比例、白色焦点与现有短转场。

- 首页取消大横幅；详情页改为小幅竖版海报，片名、播放入口与三种评分并排展示。TV 详情不再请求高清横幅。
- 分开检查硬解编码、显示 HDR 类型和音频输出。HEGE-570 按已知 HDR10/HLG、无 Dolby Vision 面板处理；其他型号按运行时能力处理。不能仅凭系统存在 Dolby Vision 解码器就向屏幕输出杜比画面。
- Media3 从容器实际格式及 codec string 判断 DV profile。兼容 Profile 7/8 的 HDR10/HLG 底层仍可硬解；没有兼容底层的 Profile 5、未知或旧 DV 格式不能强送普通 HEVC 解码器，不剥离标记伪装 SDR。清单的 DV-only 与 VIDEO-RANGE 提示也用于提前筛选。
- 严格选择可支持的轨道，避免强行启用超过解码能力的内容。若存在视频但没有可支持的视频轨道，或没有可支持的音轨，立即返回可恢复的 4005 错误，避免只出声音、没有画面后长期等待首帧。
- NAS 优先原片直连，正常 HDR10 与受支持的杜比音频不主动转码；不兼容时沿用 NAS 提供的播放流。切换保持进度与明确的播放／暂停意图，修复首次定位与原生状态包相同、页面进度却仍为零的问题。NAS 播放和探测继续直连，不绕应用代理。
- 杜比音频与视频分别选择：保留 AC-3、E-AC-3、E-AC-3 JOC 及系统支持的音频解码，按实际音响输出能力使用 AudioTrack。支持时优先杜比音轨；不能将 TrueHD 或 Atmos 输出视为该电视本机的既定能力。
- NAS 旧历史、收藏及“继续观看”按原 NAS／库／条目补齐海报与准确评分 ID。元数据两并发、队列有界并合并重复请求；不请求电影播放流。父剧集不能覆盖季身份，缓存命中也保留调用方最新播放路径。
- NAS 海报复用持久化海报目录，独立缓存最多 600 张，直连且不经过公共图片代理或 CDN 改写；键包含 NAS 账号命名空间、库与条目，不跟随会话令牌变化。先读已有图片，过期时后台刷新；带令牌的图片地址不写入历史或同步记录。
- Home Display 恢复真实航线弧线和同源后掠翼飞机几何。最多 8 条航线，飞机共用不到 600 顶点的静态缓冲；实报位置不会随时间被推算移动。明确标记的航线预览可沿路线展示，并在文字中说明“航线预览”。首次收到路线时面向路线中心，之后继续地球自转。
- 左侧航线目的地文字从 18 增至 32 逻辑像素（1280×720 基准，响应式缩放）。保留原 8K 昼夜贴图、UTC 昼夜、大气、云层与固定位置的闪烁星空；继续使用现有最多 24fps 与前后台暂停机制。

## 兼容依据与验收边界

- [华为型号表：V75 / HEGE-570](https://consumer.huawei.com/cn/support/content/zh-cn15938226/)
- [华为 HDR 说明：HDR10 / HLG](https://consumer.huawei.com/cn/support/content/zh-cn15812225/)
- [华为音轨支持表](https://consumer.huawei.com/cn/support/content/zh-cn15889164/)：V75 支持 AC3、E-AC3、DTS；表中 TrueHD 不支持。外接设备还需其自身支持，不能据此宣称本机 TrueHD/Atmos。
- [华为数字输出模式](https://consumer.huawei.com/cn/support/content/zh-cn00977171/)：自动、源码、PCM 取决于电视及外接音响能力。
- [Dolby Vision 编码与 profile 兼容性](https://professionalsupport.dolby.com/s/article/Dolby-Vision-Encoding-of-mezzanine-assets)：Profile 5 不与 HDR10/SDR 直接兼容。
- Media3 1.11.1 实际 Maven 源码 `MediaCodecVideoRenderer.getDecoderInfos` 在无 DV 显示、无兼容解码器时会继续走 soft-match；本次同时约束解码器选择、格式支持与轨道选择。

尚未读取所报 NAS 偏色影片的实际 bitstream profile，也未连接 HEGE-570 进行色彩／声音／长时间播放验收。纯 DV 的正确色彩转换依赖 NAS 现有播放流自身具备相应转换能力；客户端不能为不具备 DV 处理能力的电视凭空补充该能力。若 NAS 转换流也不能正确转换，仍需要同片的 HDR10/SDR 兼容文件。自动回归、APK 校验、参考着色器画面不代替真机验收。

TV 构建参数为 1.1.7+9，不修改桌面版本号；沿用原证书、v1/v2 签名、包名和更新入口。具体检查结果随发布包提供。
