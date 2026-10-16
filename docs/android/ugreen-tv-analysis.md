# 绿联云电视版静态分析与 Naku 3.0.2

目标：用户提供 Tv120039190917cir.apk，SHA256 d799976419e17cff0aa68dfdfa4f2a955c7c60c18fbdb40dccc65a02e44e44a4。

REA 包检查 Evidence：ev_9f0f4245028be8e37ad9d0e37d99510757b7290f8c6e875fd17ade808fd0b485。确认包名 com.ugreen.nasprotv，版本 1.20.0 (3919)，最低 API 21，目标 API 34，横屏和电视启动入口。REA 资源清单 Evidence：ev_113068e2b70b1c45e38bb6cdeef9839c1cbfe6dcaeee80188bbe19ee176a5561。

JADX 0.7.1 完整可见类清单只有 13 个外层类，包括 WrapperProxyApplication / CustomerClassLoader；APK 还包含 libshell 加固库。业务登录实现未静态恢复，不能声称确认电视版的网络协议或运行行为。

Android SDK aapt 解码的 login_activity_login.xml 明确设置可聚焦容器与焦点样式；资源包含二维码失效、已扫码状态，以及独立播放控制和进度布局。这些是静态资源证据。Naku 借鉴明确焦点、扫码状态和分层播放控制；扫码网络协议沿用本项目 macOS 已实现的 NASQRBroker，并通过 NAS 自身认证接口核对账号与设备，非从加固电视 APK 推测接口。

Naku 实现：电视仅扫码、手机扫码或密码、私人构建预填 UGlink、二维码取消/失效处理、Keystore 保存经验证会话、恢复时重新核对身份、电视分层返回。没有复制官方图标或界面素材。真实手机确认授权和电视播放需运行验收。

真实接口检查：创建接口对 Android 和 Mac profile 都返回 200；用户报告实际扫码流程显示“未知客户端类型”，因此不能仅以创建接口成功判断客户端兼容。使用既有 LOCAL_LOGIN 桌面协议 profile 后，create/qrCode 返回 code 200，包含二维码 URL 和轮询标识；保留 Android model 和 Naku 显示别名。已切换为电脑版使用的 Mac LOCAL_LOGIN profile，手机授权兼容性仍待复测。这仅验证二维码创建，不代表手机授权或 NAS 会话已验收。
