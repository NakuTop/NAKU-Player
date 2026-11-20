import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;
import 'cinema_media_transport.dart';
import 'cinema_video_metadata.dart';

const cinemaFourkAVHeaders = <String, String>{
  'User-Agent':
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15',
  'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
  'Accept-Language': 'zh-CN,zh;q=0.9',
  'Referer': 'https://4k-av.com/',
};

/// A native catalogue adapter. The site's quality labels never establish 4K.
/// Only movie/TV pages are supported; playback verifies the actual video header.
class CinemaFourkAV {
  CinemaFourkAV({CinemaMediaTransport? transport})
    : transport = transport ?? CinemaMediaTransport();
  final CinemaMediaTransport transport;
  static final _id = RegExp(
    r'^(movie|tv)/[0-9]{6,9}-[a-z0-9][a-z0-9-]{0,150}$',
  );
  static bool validId(String id) => _id.hasMatch(id);
  static bool _origin(Uri u) =>
      u.scheme == 'https' &&
      const ['4k-av.com', 'www.4k-av.com'].contains(u.host) &&
      u.userInfo.isEmpty &&
      (!u.hasPort || u.port == 443);
  static String? pageId(String raw) {
    final u = Uri.tryParse(raw);
    if (u == null || !_origin(u) || u.hasQuery || u.hasFragment) return null;
    final id = u.path
        .replaceFirst(RegExp(r'^/(?:en/)?'), '')
        .replaceFirst(RegExp(r'/$'), '');
    return validId(id) ? id : null;
  }

  static bool isPage(String raw) => pageId(raw) != null;
  static String title(String raw) => raw
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceFirst(RegExp(r'\s*第\s*\d+\s*集.*$'), '')
      .replaceFirst(RegExp(r'\s*全\s*\d+\s*集.*$'), '')
      .replaceFirst(
        RegExp(r'\s*(?:无删减)?4K(?:版)?\s*$', caseSensitive: false),
        '',
      )
      .trim();
  static const categories = [
    {'type_id': '1', 'type_name': '电影'},
    {'type_id': '2', 'type_name': '电视剧'},
  ];
  Future<String> _text(Uri uri, {CancelToken? cancel}) async => utf8
      .decode(
        await transport.bytes(
          uri,
          cinemaFourkAVHeaders,
          cancel: cancel,
          limit: 2 * 1024 * 1024,
          timeout: const Duration(seconds: 8),
          metadata: true,
        ),
      )
      .replaceFirst('\uFEFF', '');

  Future<Map<String, dynamic>> catalog(Map<String, String> query) async {
    if (query['ac'] == 'list') {
      return {'code': 1, 'list': [], 'class': categories};
    }
    final id = query['ids'];
    if (id != null) {
      if (!validId(id)) throw const FormatException('影片标识无效');
      final text = await _text(Uri.parse('https://4k-av.com/$id/'));
      return {
        'code': 1,
        'list': [parseDetail(text, id)],
        'class': categories,
      };
    }
    final page = (int.tryParse(query['pg'] ?? '') ?? 1).clamp(1, 100);
    final keyword = (query['wd'] ?? '').trim();
    final uri = Uri.https(
      '4k-av.com',
      keyword.isNotEmpty
          ? '/s'
          : query['t'] == '2'
          ? '/tv/'
          : '/movie/',
      {if (keyword.isNotEmpty) 'u': keyword, if (page > 1) 'p': '$page'},
    );
    final text = await _text(uri);
    final doc = html.parse(text);
    final items = parseSearch(text);
    var pages = page;
    for (final a in doc.querySelectorAll('a[href]')) {
      final n =
          int.tryParse(
            Uri.tryParse(a.attributes['href']!)?.queryParameters['p'] ?? '',
          ) ??
          1;
      if (n > pages) pages = n;
    }
    return {
      'code': 1,
      'page': page,
      'pagecount': pages,
      'total': items.length,
      'list': items,
      'class': categories,
    };
  }

  static Map<String, dynamic> _row(String id, String name, Element block) => {
    'vod_id': id,
    'vod_name': title(name),
    'type_id': id.startsWith('tv/') ? '2' : '1',
    'type_name': id.startsWith('tv/') ? '电视剧' : '电影',
    'vod_pic':
        block.querySelector('img[src*="poster"]')?.attributes['src'] ?? '',
    'vod_year':
        RegExp(r'\b(?:19|20)\d{2}\b')
            .firstMatch(
              block.querySelector('.resyear label[title="Years"]')?.text ??
                  block
                      .querySelector('.resyear')
                      ?.children
                      .map((e) => e.text)
                      .join(' ') ??
                  block.text,
            )
            ?.group(0) ??
        '',
    'vod_sub': block.querySelector('h3')?.text.trim() ?? '',
    'vod_remarks': '',
    'vod_play_from': '',
    'vod_play_url': '',
  };
  static List<Map<String, dynamic>> parseSearch(String text) {
    final main = html.parse(text).querySelector('#MainContent_newestlist');
    if (main == null) throw const FormatException('4K-AV 目录格式已变化');
    final seen = <String>{}, list = <Map<String, dynamic>>[];
    for (final block in main.querySelectorAll('.virow')) {
      final heading = block.querySelector('a[href] > h2');
      final href = heading?.parent?.attributes['href'];
      if (href == null ||
          !RegExp(r'4K|2160', caseSensitive: false).hasMatch(block.text)) {
        continue;
      }
      final id = pageId(
        Uri.parse('https://4k-av.com').resolve(href).toString(),
      );
      if (id == null) continue;
      final row = _row(id, heading!.text, block);
      if (seen.add(
        '${row['type_id']}::${row['vod_name']}::${row['vod_year']}',
      )) {
        list.add(row);
      }
    }
    return list;
  }

  static Map<String, dynamic> parseDetail(String text, String id) {
    if (!validId(id)) throw const FormatException('影片标识无效');
    final doc = html.parse(text),
        names = doc.querySelector('#MainContent_titleh12');
    final name = names?.querySelector('.MainTitle')?.text.trim() ?? '';
    final info = doc.querySelector('#videoinfo');
    if (name.isEmpty || info == null) {
      throw const FormatException('4K-AV 详情格式已变化');
    }
    final item = _row(id, name, info);
    item['vod_year'] =
        RegExp(r'年份:\s*((?:19|20)\d{2})')
            .firstMatch(
              doc.querySelector('#MainContent_videodetail')?.text ?? '',
            )
            ?.group(1) ??
        '';
    item['vod_sub'] = names?.querySelector('h2')?.text.trim() ?? '';
    item['vod_content'] =
        doc.querySelector('#MainContent_videodesc')?.text.trim() ?? '';
    final season = RegExp(r'第\s*(\d+)\s*季').firstMatch(name)?.group(1);
    final current = int.tryParse(
      RegExp(r'第\s*(\d+)\s*集').firstMatch(name)?.group(1) ?? '',
    );
    final episodes = <String, int?>{id: current};
    if (id.startsWith('tv/')) {
      for (final a in doc.querySelectorAll('#MainContent_reletv a[href]')) {
        final eid = pageId(
          Uri.parse(
            'https://4k-av.com',
          ).resolve(a.attributes['href']!).toString(),
        );
        final label = a.attributes['title'] ?? a.text;
        final ep = int.tryParse(
          RegExp(r'第\s*(\d+)\s*集').firstMatch(label)?.group(1) ?? '',
        );
        final s = RegExp(r'第\s*(\d+)\s*季').firstMatch(label)?.group(1);
        if (eid != null &&
            ep != null &&
            (season == null || s == null || season == s)) {
          episodes[eid] = ep;
        }
      }
    }
    final ordered = episodes.entries.toList()
      ..sort((a, b) => (a.value ?? 0).compareTo(b.value ?? 0));
    item['vod_play_from'] = '原画';
    item['vod_play_url'] = ordered
        .map(
          (e) =>
              '${e.value == null ? '正片' : '第${e.value}集'}\$https://4k-av.com/${e.key}/',
        )
        .join('#');
    return item;
  }

  Future<String> resolve(String page, {CancelToken? cancel}) async {
    final id = pageId(page);
    if (id == null) throw const FormatException('4K-AV 播放地址无效');
    final doc = html.parse(await _text(Uri.parse(page), cancel: cancel));
    final raw = doc.querySelector('video source[src]')?.attributes['src'];
    final uri = raw == null ? null : Uri.tryParse(raw);
    bool media(Uri u) =>
        _origin(u) &&
        !u.hasQuery &&
        !u.hasFragment &&
        u.path.startsWith('/$id/4K/');
    if (uri == null || !media(uri) || !uri.path.endsWith('.m3u8')) {
      throw const FormatException('此片暂未提供 4K 线路');
    }
    final manifest = await _text(uri, cancel: cancel);
    if (!manifest.startsWith('#EXTM3U')) throw const FormatException('播放清单无效');
    final map = RegExp(
      r'#EXT-X-MAP:URI="([^"]+)"',
    ).firstMatch(manifest)?.group(1);
    final init = map == null ? null : uri.resolve(map);
    if (init == null || !media(init)) {
      throw const FormatException('无法确认此线路的 4K 画质');
    }
    final bytes = await transport.bytes(
      init,
      cinemaFourkAVHeaders,
      cancel: cancel,
      limit: 512 * 1024,
      timeout: const Duration(seconds: 6),
      metadata: true,
    );
    final measured = cinemaVideoMetadata(bytes);
    if (measured == null || measured.width < 3840) {
      throw const FormatException('此线路实测未达到 4K');
    }
    return uri.toString();
  }
}
