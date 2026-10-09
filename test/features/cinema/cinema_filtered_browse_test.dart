import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_repository.dart';

class _Adapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancel,
  ) async {
    requests.add(options);
    final query = options.uri.queryParameters;
    return ResponseBody.fromString(
      jsonEncode({
        'code': 1,
        'page': query['pg'],
        'pagecount': 2,
        'class': [
          {'type_id': 1, 'type_name': '电影'},
        ],
        'list': [
          {
            'vod_id': 7,
            'vod_name': '目录项目',
            'vod_year': query['year'] ?? '2026',
          },
        ],
      }),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

const _source = CinemaSource(
  id: 'fixture',
  name: 'fixture',
  kind: CinemaSourceKind.maccms,
  url: 'https://fixture.example/api.php/provide/vod?token=public',
);
void main() {
  test(
    'filtered browse uses actual year query and does not poison ordinary page cache',
    () async {
      final adapter = _Adapter();
      final repository = CinemaRepository(
        dio: Dio()..httpClientAdapter = adapter,
      );
      final latest = await repository.browse(_source, categoryId: '1');
      final old = await repository.browseFiltered(
        _source,
        categoryId: '1',
        year: '2020',
      );
      final secondYear = await repository.browseFiltered(
        _source,
        categoryId: '1',
        year: '2019',
      );
      expect(latest.items.single.year, '2026');
      expect(old.items.single.year, '2020');
      expect(secondYear.items.single.year, '2019');
      expect(
        identical(await repository.browse(_source, categoryId: '1'), latest),
        isTrue,
      );
      expect(
        identical(
          await repository.browseFiltered(
            _source,
            categoryId: '1',
            year: '2020',
          ),
          old,
        ),
        isTrue,
      );
      expect(adapter.requests, hasLength(4));
      final query = adapter.requests[2].uri.queryParameters;
      expect(query, containsPair('token', 'public'));
      expect(query, containsPair('t', '1'));
      expect(query, containsPair('year', '2020'));
      repository.invalidateBrowseCache(source: _source);
      await repository.browseFiltered(_source, categoryId: '1', year: '2020');
      expect(adapter.requests, hasLength(6));
    },
  );
}
