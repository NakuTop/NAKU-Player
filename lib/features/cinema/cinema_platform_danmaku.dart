import 'package:dio/dio.dart';
import 'cinema_direct_danmaku.dart';
import 'cinema_logvar_client.dart';
import 'cinema_overseas_danmaku.dart';

/// Catalogue work runs in the background, independently of video loading.
class CinemaPlatformDanmakuClient implements CinemaDanmakuMatcher {
  CinemaPlatformDanmakuClient({
    double initialPosition = 0,
    CinemaDanmakuMatcher? domestic,
    CinemaDanmakuMatcher? overseas,
  }) : _domestic =
           domestic ??
           CinemaDirectDanmakuClient(initialPosition: initialPosition),
       _overseas = overseas ?? CinemaOverseasDanmakuClient();
  final CinemaDanmakuMatcher _domestic, _overseas;
  bool _closed = false;

  @override
  Future<CinemaLogvarSelection?> match(
    CinemaLogvarQuery query, {
    CancelToken? cancelToken,
    void Function(String)? onProgress,
  }) async {
    Object? domesticError;
    try {
      final value = await _domestic.match(
        query,
        cancelToken: cancelToken,
        onProgress: onProgress,
      );
      if (value != null) return value;
    } catch (error) {
      domesticError = error;
    }
    if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
    if (_closed) throw StateError('弹幕请求已关闭');
    final value = await _overseas.match(
      query,
      cancelToken: cancelToken,
      onProgress: onProgress,
    );
    if (value != null) return value;
    if (domesticError != null) throw domesticError;
    return null;
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _domestic.close();
    _overseas.close();
  }
}
