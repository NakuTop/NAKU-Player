import 'dart:io';
import 'package:dio/dio.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/request/core/network_error_mapper.dart';
import 'package:kazumi/utils/dandan_credentials.dart';
import 'package:kazumi/utils/http_headers.dart';
import 'package:kazumi/utils/crypto.dart';
import 'package:kazumi/services/platform/dandan_credential_store.dart';

class DanmakuClient {
  DanmakuClient({
    DandanCredentials? credentials,
    Dio? dio,
    Future<DandanCredentials> Function()? credentialProvider,
  }) : _credentials = credentials,
       _credentialProvider =
           credentialProvider ?? DandanCredentialStore.instance.read,
       _dio = dio;

  static final DanmakuClient instance = DanmakuClient();

  final DandanCredentials? _credentials;
  final Future<DandanCredentials> Function() _credentialProvider;
  final Dio? _dio;

  Future<dynamic> get(
    String url, {
    Map<String, dynamic>? queryParameters,
    Map<String, dynamic> headers = const {},
    CancelToken? cancelToken,
  }) async {
    final uri = Uri.parse(url);
    if (uri.scheme != 'https' ||
        uri.host != 'api.dandanplay.net' ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        !uri.path.startsWith('/api/v2/')) {
      throw const FormatException('弹弹play凭据只能用于官方 HTTPS API');
    }
    // Fail before creating a transport or a signature. Cached offline danmaku
    // does not use this client and remains available in personal builds.
    final credentials = _credentials ?? await _credentialProvider();
    if (!credentials.isConfigured) {
      throw const DanmakuNotConfiguredException();
    }
    final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final requestHeaders = <String, dynamic>{
      'user-agent': getRandomUA(),
      'referer': '',
      ...headers,
      'X-Auth': 1,
      'X-AppId': credentials.id,
      'X-Timestamp': timestamp,
      'X-Signature': generateDandanSignature(
        uri.path,
        timestamp,
        credentials: credentials,
      ),
    };

    try {
      final http = _dio ?? DioFactory.apiDio;
      var response = await http.get(
        url,
        queryParameters: queryParameters,
        options: Options(
          headers: requestHeaders,
          followRedirects: false,
          validateStatus: (code) =>
              code != null && ((code >= 200 && code < 300) || code == 302),
        ),
        cancelToken: cancelToken,
      );
      // Official comment responses can redirect to the accelerator. Never
      // forward app signatures or credentials to that second request.
      if (response.statusCode == 302) {
        final location = response.headers.value('location');
        final target = location == null ? null : uri.resolve(location);
        if (!uri.path.startsWith('/api/v2/comment/') ||
            target == null ||
            target.scheme != 'https' ||
            target.userInfo.isNotEmpty ||
            target.hasPort ||
            (InternetAddress.tryParse(target.host) != null ||
                target.host.isEmpty ||
                !target.host.contains('.') ||
                target.host.endsWith('.local') ||
                target.host.endsWith('.localhost'))) {
          throw const DanmakuServiceException('弹幕加速地址无法验证，请稍后重试');
        }
        response = await http.getUri(
          target,
          options: Options(followRedirects: false),
          cancelToken: cancelToken,
        );
      }
      final data = response.data;
      if (data is Map && data['success'] == false) {
        throw const DanmakuServiceException();
      }
      return data;
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 403 || code == 401) {
        final reason = e.response?.headers.value('x-error-message');
        throw DanmakuServiceException(
          reason == 'Invalid Timestamp'
              ? '设备时间与服务器不一致，请同步系统时间后重试'
              : '弹弹play应用未通过验证，请检查凭据、审核状态或配额',
        );
      }
      if (code == 429) {
        throw const DanmakuServiceException('弹弹play调用受限或配额已用完，请稍后重试');
      }
      throw await NetworkErrorMapper.mapException(e);
    }
  }
}
