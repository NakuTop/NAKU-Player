import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/request/config/api_endpoints.dart';
import 'package:kazumi/utils/bangumi_mirror_credentials.dart';

enum BangumiAcceleration {
  direct,
  ech,
  mirror;

  static BangumiAcceleration get current => switch (GStorage.getSetting(
    SettingsKeys.bangumiAcceleration,
  )) {
    'direct' => direct,
    'ech' => ech,
    'mirror' => mirror,
    _ => GStorage.getSetting(SettingsKeys.enableBangumiProxy) ? mirror : direct,
  };

  /// Upstream release builds inject mirror signing credentials. Personal builds
  /// can still use the official public endpoints without those private keys.
  static BangumiAcceleration forRequest(Uri uri, String method) =>
      resolveForRequest(
        mode: current,
        uri: uri,
        method: method,
        mirrorCredentialsAvailable:
            (bangumiMirrorCredentials['id']?.trim().isNotEmpty ?? false) &&
            (bangumiMirrorCredentials['value']?.trim().isNotEmpty ?? false),
      );

  static BangumiAcceleration resolveForRequest({
    required BangumiAcceleration mode,
    required Uri uri,
    required String method,
    required bool mirrorCredentialsAvailable,
  }) {
    if (mode == mirror &&
        !mirrorCredentialsAvailable &&
        requiresMirrorSignature(uri, method)) {
      return direct;
    }
    return mode;
  }

  static bool requiresMirrorSignature(Uri uri, String method) {
    if (!ApiEndpoints.bangumiPublicApiHosts.contains(uri.host)) return false;
    if (method.toUpperCase() == 'POST') {
      return uri.path == '/v0/search/subjects';
    }
    if (method.toUpperCase() != 'GET') return false;
    return uri.path.startsWith('/p1/subjects/') &&
            uri.path.endsWith('/comments') ||
        uri.path.startsWith('/p1/episodes/') &&
            uri.path.endsWith('/comments') ||
        uri.path.startsWith('/p1/characters/') &&
            uri.path.endsWith('/comments');
  }

  String get label => switch (this) {
    direct => '直连',
    ech => 'ECH',
    mirror => '镜像',
  };
}
