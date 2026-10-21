import 'package:dio/dio.dart';
import 'package:html/parser.dart' as html;
import 'cinema_subtitle_network.dart';

class CinemaSubtitleCatalogResult {
  const CinemaSubtitleCatalogResult(this.rows, this.status);
  final List<Map<String, dynamic>> rows;
  final Map<String, String> status;
}

/// Public HTML catalogs. Parse data only; never execute site JavaScript.
class CinemaSubtitleCatalogs {
  CinemaSubtitleCatalogs(this.dio);
  final Dio dio;
  final _cache = <String, CinemaSubtitleCatalogResult>{};

  Future<String> _page(Uri uri) async {
    Response<String> response;
    try {
      response = await _requestPage(uri);
    } on DioException catch (error) {
      if (![502, 503, 504].contains(error.response?.statusCode)) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 500));
      response = await _requestPage(uri);
    }
    final text = response.data ?? '';
    if (text.isEmpty || text.length > 4 * 1024 * 1024) {
      throw const FormatException('字幕网站响应无效');
    }
    return text;
  }

  Future<Response<String>> _requestPage(Uri uri) => dio.getUri<String>(
    uri,
    options: Options(
      responseType: ResponseType.plain,
      receiveTimeout: const Duration(seconds: 12),
      headers: {'Accept': 'text/html'},
    ),
  );

  static bool _safe(Uri uri, String host) =>
      uri.scheme == 'https' && uri.host == host && uri.userInfo.isEmpty;

  Future<CinemaSubtitleCatalogResult> search(
    String title,
    String type, {
    int season = 1,
    int episode = 1,
    String source = 'all',
  }) async {
    final query =
        '$title${type == 'series' ? ' S${season.toString().padLeft(2, '0')}E${episode.toString().padLeft(2, '0')}' : ''}'
            .trim();
    final key = '$source:$query';
    if (_cache.containsKey(key)) return _cache[key]!;
    final rows = <Map<String, dynamic>>[];
    final status = <String, String>{};
    await Future.wait([
      if (source == 'all' || source == 'assrt')
        () async {
          try {
            final page = await _page(
              Uri.https('assrt.net', '/sub/', {'searchword': query}),
            );
            final found = parseAssrt(page);
            rows.addAll(found);
            status['射手网'] = '${found.length} 条';
          } catch (error) {
            status['射手网'] = '${cinemaSubtitleFailureMessage(error)}，已跳过';
          }
        }(),
      if (source == 'all' || source == 'subhd')
        () async {
          try {
            final page = await _page(
              Uri.https('www.subhd.tv', '/search/$query'),
            );
            final found = parseSubHD(page);
            rows.addAll(found);
            status['SubHD'] = '${found.length} 条';
          } catch (error) {
            status['SubHD'] = '${cinemaSubtitleFailureMessage(error)}，已跳过';
          }
        }(),
    ]);
    // Failed requests are retryable; do not cache them as an empty catalog.
    final result = CinemaSubtitleCatalogResult(rows, status);
    if (!status.values.any((value) => value.contains('跳过'))) {
      _cache[key] = result;
    }
    return result;
  }

  static List<Map<String, dynamic>> parseAssrt(String page) {
    final doc = html.parse(page);
    if (doc.querySelector('#key') == null || !page.contains('searchword')) {
      throw const FormatException('射手网需要浏览器验证');
    }
    return [
      for (final item in doc.querySelectorAll('.subitem'))
        if (item.querySelector('a.introtitle') case final anchor?)
          if (RegExp(
            r'^/xml/sub/\d+/\d+\.xml$',
          ).hasMatch(anchor.attributes['href'] ?? ''))
            {
              'provider': '射手网',
              'kind': 'package',
              'url': 'https://assrt.net${anchor.attributes['href']}',
              'subtitleFileName':
                  anchor.attributes['title'] ?? anchor.text.trim(),
              'releaseFormat':
                  item.querySelector('#meta_top')?.text.trim() ?? '',
              'lang': item.querySelector('#sublangchs, #sublangcht') != null
                  ? 'zh'
                  : item.querySelector('#sublangeng') != null
                  ? 'eng'
                  : 'all',
              'bilingual': item.querySelector('#sublangdou') != null,
            },
    ];
  }

  static List<Map<String, dynamic>> parseSubHD(String page) {
    final doc = html.parse(page);
    if (doc.querySelector('input[name="subhd_search"]') == null) {
      throw const FormatException('SubHD 需要浏览器验证');
    }
    final seen = <String>{};
    return [
      for (final anchor in doc.querySelectorAll('.view-text a[href^="/a/"]'))
        if (RegExp(
              r'^/a/[a-zA-Z0-9]+$',
            ).hasMatch(anchor.attributes['href'] ?? '') &&
            seen.add(anchor.attributes['href']!))
          {
            'provider': 'SubHD',
            'kind': 'package',
            'url': 'https://www.subhd.tv${anchor.attributes['href']}',
            'subtitleFileName': anchor.text.trim(),
            'releaseFormat':
                anchor.parent?.parent
                    ?.querySelector('.fw-bold a')
                    ?.text
                    .trim() ??
                '',
            'lang':
                RegExp('简体|繁体|中文').hasMatch(anchor.parent?.parent?.text ?? '')
                ? 'zh'
                : RegExp(
                    r'英语|英文|English',
                    caseSensitive: false,
                  ).hasMatch(anchor.parent?.parent?.text ?? '')
                ? 'eng'
                : 'all',
            'bilingual': (anchor.parent?.parent?.text ?? '').contains('双语'),
          },
    ];
  }

  static String _fileLanguage(String name, String fallback) {
    if (RegExp(
      r'简|繁|中英|中文|(?<![a-z])(?:chs|cht|chi|zho|zh)(?![a-z])',
      caseSensitive: false,
    ).hasMatch(name)) {
      return 'zh';
    }
    if (RegExp(
      r'英文|英语|(?<![a-z])(?:english|eng|en)(?![a-z])',
      caseSensitive: false,
    ).hasMatch(name)) {
      return 'eng';
    }
    return fallback;
  }

  Future<List<Map<String, dynamic>>> files(Map<String, dynamic> package) async {
    final uri = Uri.parse('${package['url']}');
    final assrt = package['provider'] == '射手网';
    if (!_safe(uri, assrt ? 'assrt.net' : 'www.subhd.tv')) {
      throw const FormatException('字幕来源链接无效');
    }
    final page = await _page(uri);
    if (!assrt) {
      final doc = html.parse(page);
      final sid = doc
          .querySelector('.subtitle-prepare-download')
          ?.attributes['data-sid'];
      if (sid == null || !RegExp(r'^[a-zA-Z0-9]+$').hasMatch(sid)) {
        throw const FormatException('SubHD 资源暂不可直接下载');
      }
      final response = await dio.postUri<dynamic>(
        Uri.https('www.subhd.tv', '/api/sub/prepare-download'),
        data: {'sid': sid},
        options: Options(headers: {'Referer': uri.toString()}),
      );
      final data = response.data;
      final path = data is Map && data['success'] == true ? data['url'] : null;
      if (path is! String ||
          !path.startsWith('/down/') ||
          !_safe(uri.resolve(path), 'www.subhd.tv')) {
        throw const FormatException('SubHD 资源需要交互验证，已跳过');
      }
      return [
        for (final node in doc.querySelectorAll('[data-filename]'))
          if (node.attributes['data-filename'] case final String name)
            if (RegExp(
              r'\.(ass|ssa|srt|vtt)$',
              caseSensitive: false,
            ).hasMatch(name))
              {
                'provider': 'SubHD',
                'url': uri.resolve(path).toString(),
                'archiveEntry': name,
                'subtitleFileName': name,
                'sourceUrl': uri.toString(),
                'lang': _fileLanguage(name, '${package['lang']}'),
                'bilingual': package['bilingual'],
                'releaseFormat':
                    '${package['subtitleFileName'] ?? ''} ${package['releaseFormat'] ?? ''}',
              },
      ];
    }
    final doc = html.parse(page);
    final download = doc.querySelector('a#btn_download')?.attributes['href'];
    final downloadUri = download == null ? null : uri.resolve(download);
    if (downloadUri == null ||
        !_safe(downloadUri, 'assrt.net') ||
        !downloadUri.path.startsWith('/download/')) {
      throw const FormatException('该字幕包暂时无法下载，请打开来源页面');
    }
    final names = doc
        .querySelectorAll('#detail-filelist #filelist-name')
        .map((node) => node.text.trim())
        .where(
          (name) => RegExp(
            r'\.(ass|ssa|srt|vtt)$',
            caseSensitive: false,
          ).hasMatch(name),
        )
        .toList();
    return [
      for (final name in names)
        {
          'provider': '射手网',
          'url': downloadUri.toString(),
          'sourceUrl': uri.toString(),
          'archiveEntry': name,
          'subtitleFileName': name,
          'lang': _fileLanguage(name, '${package['lang']}'),
          'bilingual': package['bilingual'],
          'releaseFormat':
              '${package['subtitleFileName'] ?? ''} ${package['releaseFormat'] ?? ''}',
        },
    ];
  }
}
