# 窗口隐藏与整窗透明度

macOS 2.0.3 的入口为「设置 → 窗口与快捷隐藏」。默认 ⌘B 可在其他应用中隐藏或显示 NAKU 的原窗口；可选择 ⌃⌥B、⌘⇧H、F8 或 F9。功能键可能需要配合 fn。关闭快捷键不影响应用菜单及托盘的恢复入口。快捷键占用时会提示原因，原设置和已注册的旧快捷键保留；其他应用退出后可重新注册。窗口设置随完整片库的设置备份导出，并在下次启动时读取恢复值。

「隐藏时自动暂停」默认关闭，与「后台播放」的最小化策略分开。开启后，电影、剧集和动漫在隐藏时暂停，打开尚未完成的视频也不会在隐藏期间自动开始播放；显示窗口不主动调用播放。全屏动画和普通失焦不视为隐藏。2.0.3 使用应用实际隐藏状态，不把启动或全屏切换时窗口暂时不可见视为隐藏；显示、激活及手动播放前校准状态，避免恢复后第一次点击播放或按空格被旧状态阻止。此设置不暂停独立的下载任务。

「整窗半透明」默认关闭，开启后整个主窗口（包括视频、文字和按钮）使用 30%–100% 不透明度。它与「外观与透明度」中的背景磨砂浓淡分开保存，切换焦点不改变设定。macOS「减少透明度」启用时临时保持整窗不透明，仍保留用户设置。

## taskManagerRunner 的 REA 依据

分析对象为本机 `/Applications/taskManagerRunner.app`，版本 4.8.1；其 `app.asar` SHA-256 为 `2237fc39d4a67ddd1022bf8add84a391a90cd363953c6f9f9a7b97cc81b5bc5a`。分析只读取安装包，不启动应用、不读取账号配置。

完整 ASAR 分析超过 MCP 180 秒时限，未取得完整记录；后续对带原路径和字节摘要的 package / preload / 字节码入口片段进行了聚焦静态分析，未重复运行完整分析。

- REA 应用证据：`ev_846ae674e99fcba572e20b2a71abb5e5acbb215d9c39a24041ccf05c11ec1f57`。解析了三个 JavaScript 文件；preload 提供 `toggleMainWindow`、`toggle-window` IPC 和快捷键配置、冲突检测接口。
- 切换窗口的聚焦追踪证据：`ev_4ae692afe6f710f550ff852fc91abd72ac14df0581f6af453c309fd01c66ed8d`，匹配一个 IPC 通道、追踪五个节点和五条关系。它只确认静态接口关系，不证明主进程已执行。
- `electron/shortcuts.jsc` 的字节串可见 Command/Ctrl+B 切换窗口、Command/Ctrl+[ / ] 调透明度，以及 `hideMainWindow`、`showMainWindow`、`getOpacity`、`setOpacity` 和配置保存线索。主处理器属于 V8 字节码，控制流、步长和默认值未完整还原；这些字符串不是运行时验证。

NAKU 使用独立编写的 AppKit `NSApplication.hide/unhide`、`NSWindow.alphaValue` 和 Carbon `RegisterEventHotKey` 实现上述行为，没有复制目标程序代码或引入其账户、截图、鼠标穿透等功能。系统热键在应用隐藏时仍有效，不通过全局键盘监听或辅助功能权限读取用户输入。

## 复核

```sh
flutter test --no-pub test/desktop_window_controls_test.dart test/features/cinema/cinema_desktop_window_settings_test.dart test/features/cinema/cinema_quality_test.dart
swiftc macos/Runner/NakuDesktopWindowController.swift scripts/check_desktop_window_controls.swift -o /tmp/naku-desktop-window-check
/tmp/naku-desktop-window-check
```

原生检查运行自己创建的测试窗口，检查初始窗口暂时不可见及重复显示通知的状态修复、全局热键注册 / 冲突 / 释放、透明度限值及关闭恢复，并通过 Carbon 热键事件受控派发检查同窗口隐藏 / 显示和按键长按防重复触发。检查也可使用发行沙盒权限执行。它不会替代安装版的真实键盘、媒体解码和全屏播放验收；本机已安装播放器由用户手动更新。
