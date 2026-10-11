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
    // Fail before creating a transport or a signature. Cached offline danmaku
    // does not use this client and remains available in personal builds.
    final credentials = _credentials ?? await _credentialProvider();
    if (!credentials.isConfigured) {
      throw const DanmakuNotConfiguredException();
    }
    final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final uri = Uri.parse(url);
    final requestHeaders = <String, dynamic>{
      'user-agent': getRandomUA(),
      'referer': '',
      'X-Auth': 1,
      'X-AppId': credentials.id,
      'X-Timestamp': timestamp,
      'X-Signature': generateDandanSignature(
        uri.path,
        timestamp,
        credentials: credentials,
      ),
      ...headers,
    };

    try {
      final response = await (_dio ?? DioFactory.apiDio).get(
        url,
        queryParameters: queryParameters,
        options: Options(headers: requestHeaders),
        cancelToken: cancelToken,
      );
      final data = response.data;
      if (data is Map && data['success'] == false) {
        throw const DanmakuServiceException();
      }
      return data;
    } on DioException catch (e) {
      throw await NetworkErrorMapper.mapException(e);
    }
  }
}
