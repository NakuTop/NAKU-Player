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

  static const message = '尚未配置弹幕服务，请在弹幕设置填写凭据，或导入本地弹幕';

  @override
  String toString() => message;
}

class DanmakuServiceException implements Exception {
  const DanmakuServiceException([this.message = '弹幕服务未通过验证，请检查凭据或稍后重试']);
  final String message;
  @override
  String toString() => message;
}

String danmakuFailureMessage(
  Object? error, {
  String fallback = '弹幕加载失败，可手动检索',
}) => error is DanmakuNotConfiguredException
    ? DanmakuNotConfiguredException.message
    : error is DanmakuServiceException
    ? error.toString()
    : fallback;
