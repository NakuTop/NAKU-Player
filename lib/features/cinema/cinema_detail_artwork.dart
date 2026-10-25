import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:html/parser.dart' as html;
import 'package:kazumi/services/network/macos_system_proxy.dart';
import 'package:kazumi/services/network/proxy_aware_image_cache_manager.dart';

import 'cinema_douban_access.dart';
import 'cinema_models.dart';
import 'cinema_ratings.dart';
import 'douban/douban_image_headers.dart';

typedef CinemaArtworkFetch =
    Future<Uint8List> Function(
      Uri uri,
      Map<String, String> headers,
      int maxBytes,
      CancelToken cancel,
    );
typedef CinemaArtworkInspect =
    Future<(int, int)> Function(
      String url,
      Map<String, String> headers,
      CancelToken cancel,
    );

class CinemaDetailArtwork {
  const CinemaDetailArtwork({
    required this.url,
    this.width = 0,
    this.height = 0,
    this.highResolution = false,
  });
  final String url;
  final int width, height;
  final bool highResolution;
  Map<String, String> get headers =>
      Uri.tryParse(url)?.host.endsWith('.doubanio.com') == true
      ? doubanImageHeaders
      : const {};
}

/// Exact-ID artwork lookup. A large decode target never counts as a large file.
class CinemaDetailArtworkRepository {
  CinemaDetailArtworkRepository({
    CinemaArtworkFetch? fetch,
    CinemaArtworkInspect? inspect,
    this.deadline = const Duration(seconds: 12),
    DateTime Function()? now,
  }) : _fetch = fetch ?? _fetchBytes,
       _inspectOverride = inspect,
       _now = now ?? DateTime.now;
  static final instance = CinemaDetailArtworkRepository();
  final CinemaArtworkFetch _fetch;
  final CinemaArtworkInspect? _inspectOverride;
  final Duration deadline;
  final DateTime Function() _now;
  final _cache = <String, (DateTime, CinemaDetailArtwork?)>{};
  final _metadata = <String, (DateTime, Map<String, dynamic>)>{};

  static String kind(CinemaTitle title) {
    final value = title.category.toLowerCase();
    if (RegExp(r'剧|series|\btv\b').hasMatch(value)) return 'series';
    if (RegExp(r'电影|片|movie|film').hasMatch(value)) return 'movie';
    return '';
  }

  static String identityKey(CinemaTitle title, RatingIdentity identity) =>
      jsonEncode([
        title.key,
        title.poster,
        title.doubanId,
        title.imdbId,
        identity.doubanId,
        identity.imdbId,
        kind(title),
      ]);

  Future<CinemaDetailArtwork> resolve(
    CinemaTitle title, {
    RatingIdentity identity = const RatingIdentity(),
    CancelToken? cancelToken,
    bool Function()? isCurrent,
  }) async {
    final fallback = CinemaDetailArtwork(url: title.poster);
    if ((title.doubanId.isNotEmpty &&
            identity.doubanId.isNotEmpty &&
            title.doubanId != identity.doubanId) ||
        (title.imdbId.isNotEmpty &&
            identity.imdbId.isNotEmpty &&
            title.imdbId != identity.imdbId)) {
      return fallback;
    }
    final douban = title.doubanId.isNotEmpty
        ? title.doubanId
        : identity.doubanId;
    final imdb = title.imdbId.isNotEmpty ? title.imdbId : identity.imdbId;
    final validDouban = RegExp(r'^[1-9][0-9]{1,11}$').hasMatch(douban);
    final validImdb = RegExp(r'^tt[0-9]{7,10}$').hasMatch(imdb);
    final type = kind(title);
    if (!validDouban && !(validImdb && type.isNotEmpty)) return fallback;
    void current() {
      _checkCancel(cancelToken);
      if (isCurrent?.call() == false) {
        throw StateError('Artwork request superseded');
      }
    }

    current();
    final key = '$douban|$imdb|$type';
    final cached = _cache[key];
    if (cached != null && _now().isBefore(cached.$1)) {
      return cached.$2 ?? fallback;
    }
    final cancel = CancelToken();
    cancelToken?.whenCancel.then((error) => cancel.cancel(error));
    final timer = Timer(
      deadline,
      () => cancel.cancel('Artwork lookup deadline'),
    );
    try {
      final candidates = <String>[];
      String doubanPoster = '';
      await Future.wait([
        if (validImdb && type.isNotEmpty)
          (() async {
            try {
              final data = await _json(
                Uri.https('v3-cinemeta.strem.io', '/meta/$type/$imdb.json'),
                cancel,
              );
              final meta = data['meta'];
              if (meta is! Map || meta['id'] != imdb || meta['type'] != type) {
                return;
              }
              // Only literal provider URLs; never rewrite a thumbnail's size.
              for (final field in ['background', 'poster']) {
                final image = _imageUrl(meta[field]);
                final advertisedId = RegExp(
                  r'/((?:tt)[0-9]{7,10})/',
                ).firstMatch(Uri.tryParse(image)?.path ?? '')?.group(1);
                if (advertisedId != null && advertisedId != imdb) continue;
                if (image.isNotEmpty) candidates.add(image);
              }
            } catch (_) {
              /* A second exact-ID provider may still have artwork. */
            }
          })(),
        if (validDouban)
          (() async {
            try {
              final feed = CinemaDoubanAccess.feedSubject(douban)?.$2;
              final data =
                  feed ??
                  (CinemaDoubanAccess.canRequestSubject()
                      ? await _json(
                          Uri.https(
                            'm.douban.com',
                            '/rexxar/api/v2/${type == 'series' ? 'tv' : 'movie'}/$douban',
                          ),
                          cancel,
                        )
                      : <String, dynamic>{});
              if (data['id']?.toString() != douban ||
                  !['movie', 'tv'].contains(data['type']) ||
                  (data['url'] != null &&
                      doubanIdFromUrl('${data['url']}') != douban) ||
                  (type.isNotEmpty &&
                      data['type'] != (type == 'series' ? 'tv' : 'movie'))) {
                return;
              }
              final pic = data['pic'];
              if (pic is Map) doubanPoster = _imageUrl(pic['large']);
            } catch (_) {
              /* Missing/limited official metadata keeps the fallback. */
            }
          })(),
      ]);
      current();
      _checkCancel(cancel);
      // A landscape image is tried before portrait posters, regardless of which
      // concurrent metadata request finished first.
      if (doubanPoster.isNotEmpty) candidates.add(doubanPoster);
      for (final url in candidates.toSet().take(3)) {
        final result = await _verified(url, cancel);
        current();
        if (result != null) {
          _remember(key, result);
          return result;
        }
      }
      // Douban's subject API often supplies a 450px image as "large". Its own
      // photo page may publish a real original for that exact same photo ID.
      final photo = _doubanPhotoId(doubanPoster);
      if (photo.isNotEmpty) {
        try {
          final page = await _race(
            _fetch(
              Uri.https('movie.douban.com', '/photos/photo/$photo/'),
              const {},
              2 * 1024 * 1024,
              cancel,
            ),
            cancel,
          );
          final document = html.parse(utf8.decode(page));
          final canonical = document
              .querySelector('link[rel="canonical"]')
              ?.attributes['href'];
          final canonicalUri = Uri.tryParse(canonical ?? '');
          if (canonicalUri?.scheme == 'https' &&
              canonicalUri?.host == 'movie.douban.com' &&
              canonicalUri?.path == '/photos/photo/$photo/') {
            final images = document.querySelectorAll(
              'img[src],meta[property="og:image"]',
            );
            for (final image in images) {
              final url = _imageUrl(
                image.attributes['src'] ?? image.attributes['content'],
              );
              if (_doubanPhotoId(url) != photo || candidates.contains(url)) {
                continue;
              }
              final result = await _verified(url, cancel);
              current();
              if (result != null) {
                _remember(key, result);
                return result;
              }
            }
          }
        } catch (_) {
          /* A challenged photo page is not an HD success. */
        }
      }
      current();
    } catch (_) {
      // A closed/replaced detail must neither publish nor poison shared caches.
      current();
    } finally {
      timer.cancel();
    }
    _remember(key, null);
    return fallback;
  }

  void _remember(String key, CinemaDetailArtwork? artwork) {
    _cache.remove(key);
    _cache[key] = (
      _now().add(
        artwork == null
            ? const Duration(seconds: 30)
            : const Duration(hours: 24),
      ),
      artwork,
    );
    while (_cache.length > 48) {
      _cache.remove(_cache.keys.first);
    }
  }

  Future<CinemaDetailArtwork?> _verified(String url, CancelToken cancel) async {
    try {
      _checkCancel(cancel);
      final candidate = CinemaDetailArtwork(url: url);
      final size = await _race(
        _inspectOverride?.call(url, candidate.headers, cancel) ??
            _inspect(url, candidate.headers, cancel),
        cancel,
      );
      _checkCancel(cancel);
      final (width, height) = size;
      final hd =
          width >= 1280 && height >= 720 || width >= 1000 && height >= 1400;
      if (!hd || width > 16384 || height > 16384 || width * height > 80000000) {
        return null;
      }
      return CinemaDetailArtwork(
        url: url,
        width: width,
        height: height,
        highResolution: true,
      );
    } catch (_) {
      return null;
    }
  }

  Future<(int, int)> _inspect(
    String url,
    Map<String, String> headers,
    CancelToken cancel,
  ) async {
    final manager = ProxyAwareImageCacheManager.cinemaInstance;
    final cached = await manager.getFileFromCache(url);
    File file;
    if (cached != null &&
        cached.validTill.isAfter(_now()) &&
        await cached.file.exists()) {
      file = cached.file;
    } else {
      final bytes = await _race(
        _fetch(Uri.parse(url), headers, 12 * 1024 * 1024, cancel),
        cancel,
      );
      _checkCancel(cancel);
      file = await manager.putFile(
        url,
        bytes,
        fileExtension: 'img',
        maxAge: const Duration(days: 7),
      );
    }
    _checkCancel(cancel);
    return readOriginalDimensions(file);
  }

  static Future<(int, int)> readOriginalDimensions(File file) async {
    if (await file.length() > 12 * 1024 * 1024) {
      throw const FormatException('Artwork file too large');
    }
    final buffer = await ui.ImmutableBuffer.fromFilePath(file.path);
    try {
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      try {
        return (descriptor.width, descriptor.height);
      } finally {
        descriptor.dispose();
      }
    } finally {
      buffer.dispose();
    }
  }

  Future<Map<String, dynamic>> _json(Uri uri, CancelToken cancel) async {
    final cached = _metadata[uri.toString()];
    if (cached != null &&
        _now().difference(cached.$1) < const Duration(hours: 6)) {
      return cached.$2;
    }
    final data = jsonDecode(
      utf8.decode(
        await _race(_fetch(uri, const {}, 512 * 1024, cancel), cancel),
      ),
    );
    if (data is! Map) throw const FormatException('Artwork metadata invalid');
    _checkCancel(cancel);
    final result = Map<String, dynamic>.from(data);
    _metadata[uri.toString()] = (_now(), result);
    while (_metadata.length > 96) {
      _metadata.remove(_metadata.keys.first);
    }
    return result;
  }

  static String _imageUrl(Object? value) {
    final uri = value is String ? Uri.tryParse(value) : null;
    return uri != null &&
            uri.scheme == 'https' &&
            uri.host.isNotEmpty &&
            uri.userInfo.isEmpty &&
            !uri.hasPort
        ? uri.toString()
        : '';
  }

  static void _checkCancel(CancelToken? cancel) {
    if (cancel?.isCancelled == true) throw cancel!.cancelError!;
  }

  static Future<T> _race<T>(Future<T> work, CancelToken cancel) =>
      Future.any([work, cancel.whenCancel.then<T>((error) => throw error)]);

  static String _doubanPhotoId(String url) {
    final uri = Uri.tryParse(url);
    if (uri?.host.endsWith('.doubanio.com') != true) return '';
    return RegExp(
          r'^/view/photo/[^/]+/public/p([0-9]+)\.(?:jpg|jpeg|webp|png)$',
        ).firstMatch(uri!.path)?.group(1) ??
        '';
  }

  static Future<Uint8List> _fetchBytes(
    Uri uri,
    Map<String, String> headers,
    int maxBytes,
    CancelToken cancel,
  ) async {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 4),
        receiveTimeout: const Duration(seconds: 6),
        sendTimeout: const Duration(seconds: 4),
      ),
    );
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        client.findProxy = Platform.isMacOS
            ? MacOSSystemProxy.findProxy
            : HttpClient.findProxyFromEnvironment;
        return client;
      },
    );
    try {
      var target = uri;
      Response<ResponseBody>? response;
      for (var hop = 0; hop <= 2; hop++) {
        response = await dio.getUri<ResponseBody>(
          target,
          cancelToken: cancel,
          options: Options(
            responseType: ResponseType.stream,
            followRedirects: false,
            validateStatus: (status) =>
                status == 200 ||
                const [301, 302, 303, 307, 308].contains(status),
            headers: {
              'User-Agent': 'NAKUPlayer/2.12.4',
              if (target.host.endsWith('douban.com'))
                'Referer': target.path.startsWith('/rexxar/api/')
                    ? 'https://m.douban.com/movie/subject/${target.pathSegments.last}/'
                    : 'https://movie.douban.com/',
              ...headers,
            },
          ),
        );
        if (response.statusCode == 200) break;
        final location = response.headers.value('location');
        final redirected = location == null ? null : target.resolve(location);
        await response.data?.stream.drain<void>();
        if (hop == 2 ||
            redirected == null ||
            _imageUrl(redirected.toString()).isEmpty ||
            (target.host == 'm.douban.com' &&
                target.path.startsWith('/rexxar/api/') &&
                CinemaDoubanAccess.subjectRedirect(target, location) !=
                    redirected)) {
          throw const FormatException('Artwork redirect rejected');
        }
        target = redirected;
      }
      final body = response!.data!;
      final length = int.tryParse(
        body.headers['content-length']?.firstOrNull ?? '',
      );
      if (length != null && length > maxBytes) {
        throw const FormatException('Artwork response too large');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final part in body.stream) {
        if (bytes.length + part.length > maxBytes) {
          throw const FormatException('Artwork response too large');
        }
        bytes.add(part);
      }
      return bytes.takeBytes();
    } finally {
      dio.close(force: true);
    }
  }
}
