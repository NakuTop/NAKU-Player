import 'dart:io';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/network/resilient_read_adapter.dart';

class RealHttpOverrides extends HttpOverrides {}

void main() {
  for (final url in [
    'https://api.bgm.tv/v0/subjects/899',
    'https://api.guangsuapi.com/api.php/provide/vod/',
    'https://jszyapi.com/api.php/provide/vod/',
  ]) {
    test('direct plus encrypted fallback: $url', () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final dio = Dio(
          BaseOptions(receiveTimeout: const Duration(seconds: 12)),
        );
        dio.httpClientAdapter = ResilientReadAdapter(
          primaryFactory: () => IOHttpClientAdapter(
            createHttpClient: () => HttpClient()..findProxy = (_) => 'DIRECT',
          ),
          proxy: (_) => null,
          refresh: () async {},
          revision: () => 0,
        );
        try {
          final response = await dio
              .get<dynamic>(url)
              .timeout(const Duration(seconds: 35));
          expect(response.statusCode, 200);
          expect(
            response.data is String
                ? jsonDecode(response.data as String)
                : response.data,
            isA<Map>(),
          );
          // ignore: avoid_print
          print('LIVE HTTP 200 JSON: $url');
        } on DioException catch (error) {
          // ignore: avoid_print
          print('LIVE FAILURE $url: ${error.error}');
          rethrow;
        } finally {
          dio.close(force: true);
        }
      }, RealHttpOverrides());
    }, skip: Platform.environment['NAKU_LIVE_NETWORK'] != '1');
  }
}
