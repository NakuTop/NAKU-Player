// DanDanPlay API credentials for the client signature flow.
// Release/PR CI injects them via --dart-define=DANDANAPI_APPID / DANDANAPI_KEY.
const dandanCredentials = DandanCredentials(
  id: String.fromEnvironment('DANDANAPI_APPID'),
  secret: String.fromEnvironment('DANDANAPI_KEY'),
);

class DandanCredentials {
  const DandanCredentials({required this.id, required this.secret});

  final String id;
  final String secret;

  bool get isConfigured => id.trim().isNotEmpty && secret.trim().isNotEmpty;
}

class DanmakuNotConfiguredException implements Exception {
  const DanmakuNotConfiguredException();

  static const message = '此版本尚未配置弹幕服务，请在弹幕设置查看说明';

  @override
  String toString() => message;
}

String danmakuFailureMessage(
  Object? error, {
  String fallback = '弹幕加载失败，可手动检索',
}) => error is DanmakuNotConfiguredException
    ? DanmakuNotConfiguredException.message
    : fallback;
