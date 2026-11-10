import 'dart:io';
import 'package:ech_http/ech_http.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;
import 'package:kazumi/services/network/bangumi_ech_image_service.dart';
import 'package:kazumi/services/network/bangumi_image_url_rewriter.dart';
import 'package:kazumi/services/network/image_acceleration.dart';
import 'package:kazumi/services/network/image_file_response.dart';
import 'package:kazumi/features/cinema/douban/douban_image_headers.dart';

class ImageFileService extends FileService {
  ImageFileService({
    required ImageAcceleration Function() acceleration,
    required http.Client Function() clientFactory,
    required BangumiEchImageService echService,
  }) : _acceleration = acceleration,
       _clientFactory = clientFactory,
       _echService = echService;

  final ImageAcceleration Function() _acceleration;
  final http.Client Function() _clientFactory;
  final BangumiEchImageService _echService;
  final _clients = <http.Client, int>{};
  http.Client? _client;
  bool _closed = false;

  void resetNetworkClients() {
    _echService.reset();
    final previous = _client;
    _client = null;
    if (previous != null && _clients[previous] == 0) {
      _clients.remove(previous);
      previous.close();
    }
  }

  void close() {
    _closed = true;
    _echService.close();
    for (final client in _clients.keys.toList()) {
      client.close();
    }
    _clients.clear();
    _client = null;
  }

  @override
  Future<FileServiceResponse> get(
    String url, {
    Map<String, String>? headers,
  }) async {
    if (_closed) throw StateError('Image file service is closed');
    final mode = _acceleration();
    var uri = Uri.parse(url);
    if (mode == ImageAcceleration.ech &&
        BangumiImageUrlRewriter.isBangumiImage(uri)) {
      try {
        return await _echService.get(
          uri.replace(scheme: 'https').toString(),
          headers: headers,
        );
      } on EchException catch (error) {
        // Retry transport failures only; certificate rejection remains final.
        if (!Platform.isMacOS ||
            !{5, 6, 7, 28, 35, 52, 55, 56}.contains(error.nativeCode)) {
          rethrow;
        }
        if (_closed) rethrow;
        uri = uri.replace(scheme: 'https');
      }
    }
    if (mode == ImageAcceleration.mirror) {
      uri = BangumiImageUrlRewriter.rewrite(uri);
    }

    // Reuse TCP/TLS sessions and successful fallback routes across the grid.
    // A settings reset retires the old client once its current bodies finish.
    final client = _client ??= _clientFactory();
    _clients[client] = (_clients[client] ?? 0) + 1;
    final http.StreamedResponse response;
    try {
      final request = http.Request('GET', uri);
      if (headers != null) request.headers.addAll(headers);
      // Aggregation can retain a Douban poster on a different source's title.
      // CDN requirements belong to the image host, not the catalogue source ID.
      if (uri.host.toLowerCase().endsWith('.doubanio.com')) {
        for (final entry in doubanImageHeaders.entries) {
          request.headers.putIfAbsent(entry.key, () => entry.value);
        }
      }
      response = await client.send(request);
    } catch (_) {
      _release(client);
      rethrow;
    }
    return createImageFileResponse(
      response,
      contentLength: response.contentLength,
      onComplete: () => _release(client),
    );
  }

  void _release(http.Client client) {
    final active = _clients[client];
    if (active == null) return;
    _clients[client] = active - 1;
    if (active == 1 && client != _client) {
      _clients.remove(client);
      client.close();
    }
  }
}
