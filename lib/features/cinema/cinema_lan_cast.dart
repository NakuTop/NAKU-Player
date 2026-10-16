import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kazumi/services/platform/naku_device.dart';
import 'cinema_android_nas.dart';
import 'cinema_models.dart';
import 'cinema_nas_media.dart';

/// Reject stale, cross-account and replayed commands after authenticated decryption.
class CinemaCastReplayGuard {
  final _seen = <String>{};
  void clear() => _seen.clear();
  void accept(Map<String, dynamic> data, String expected, {int? now}) {
    final timestamp = data['timestamp'], nonce = '${data['nonce']}';
    if (expected.isEmpty ||
        data['namespace'] != expected ||
        timestamp is! int ||
        ((now ?? DateTime.now().millisecondsSinceEpoch) - timestamp).abs() >
            30000 ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(nonce) ||
        _seen.contains(nonce) ||
        _seen.length >= 10000) {
      throw const FormatException('无效或过期的播放请求');
    }
    _seen.add(nonce);
  }
}

/// The LAN advert contains only a random ID. Its encryption key can be obtained
/// only through the logged-in account's private NAS directory, not from NSD.
class CinemaLanCast extends ChangeNotifier {
  static final instance = CinemaLanCast();
  static const _channel = MethodChannel('naku/lan'),
      _secure = MethodChannel('naku/secure');
  final Map<String, Map<String, dynamic>> televisions = {};
  final _nas = CinemaNASClient();
  final _random = Random.secure();
  final _replay = CinemaCastReplayGuard();
  HttpServer? _server;
  Timer? _timer;
  String _namespace = '', _secret = '', _id = '', status = '登录 NAS 后可接收手机发送的影片';
  DateTime _started = DateTime(2000);
  bool _refreshing = false;
  int _generation = 0;
  Future<void> Function(CinemaTitle, CinemaSource, int, int, int)? onPlay;
  String _randomHex() => List.generate(
    16,
    (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  void start() {
    if (!Platform.isAndroid) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'found') {
        final row = Map<String, dynamic>.from(call.arguments as Map),
            id = '${(call.arguments as Map)['id']}';
        if (RegExp(r'^[a-f0-9]{32}$').hasMatch(id) &&
            CinemaAndroidNAS.privateIPv4('${row['host']}')) {
          televisions[id] = row;
        }
      } else if (call.method == 'lost') {
        televisions.remove('${call.arguments}');
      } else if (call.method == 'error') {
        status = '${call.arguments}';
      }
      notifyListeners();
    });
    if (NakuDevice.isTV) {
      _timer ??= Timer.periodic(
        const Duration(seconds: 10),
        (_) => unawaited(_refresh()),
      );
      unawaited(_refresh());
    }
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    final generation = _generation;
    try {
      final current = await _nas.call('currentSession'),
          ns = current['namespace'] as String? ?? '';
      if (generation != _generation || onPlay == null) return;
      if (ns == _namespace &&
          _server != null &&
          DateTime.now().difference(_started).inHours < 10) {
        return;
      }
      if (_server != null) {
        await _server!.close(force: true);
        _server = null;
        await _channel.invokeMethod<void>('stop');
      }
      _namespace = ns;
      _replay.clear();
      if (ns.isEmpty) {
        status = '登录 NAS 后可接收手机发送的影片';
        return;
      }
      _secret = _randomHex();
      _id = _randomHex();
      await _nas.call('castPublish', {
        'namespace': ns,
        'id': _id,
        'secret': _secret,
      });
      if (generation != _generation || onPlay == null) return;
      final server = await HttpServer.bind(
        InternetAddress.anyIPv4,
        0,
        shared: false,
      );
      if (generation != _generation || onPlay == null) {
        await server.close(force: true);
        return;
      }
      _server = server;
      _server!.listen((r) => unawaited(_receive(r)));
      _started = DateTime.now();
      await _channel.invokeMethod<void>('advertise', {
        'id': _id,
        'port': _server!.port,
      });
      status = '已就绪 · 手机可发送影片到这台电视';
    } catch (_) {
      status = '电视接收尚未就绪，请检查 NAS 连接与个人目录权限';
    } finally {
      _refreshing = false;
      notifyListeners();
    }
  }

  Future<void> _receive(HttpRequest request) async {
    try {
      if (request.method != 'POST' ||
          request.uri.path != '/play' ||
          !CinemaAndroidNAS.privateIPv4(
            request.connectionInfo?.remoteAddress.address ?? '',
          )) {
        throw const FormatException();
      }
      final bytes = <int>[];
      await for (final chunk in request.timeout(const Duration(seconds: 8))) {
        bytes.addAll(chunk);
        if (bytes.length > 524288) throw const FormatException();
      }
      final envelope = jsonDecode(utf8.decode(bytes)) as Map;
      final clear = await _secure.invokeMethod<String>('open', {
        'text': envelope['payload'],
        'key': _secret,
      });
      final data = Map<String, dynamic>.from(jsonDecode(clear!) as Map);
      final current = await _nas.call('currentSession');
      if (current['namespace'] != _namespace) throw const FormatException();
      _replay.accept(data, _namespace);
      final title = CinemaTitle.fromJson(
            Map<String, dynamic>.from(data['title'] as Map),
          ),
          source = CinemaSource.fromJson(
            Map<String, dynamic>.from(data['source'] as Map),
          );
      source.validate();
      final road = data['road'] as int,
          episode = data['episode'] as int,
          position = data['position'] as int;
      if (road < 0 ||
          road >= title.routes.length ||
          episode < 0 ||
          episode >= title.routes[road].episodes.length ||
          position < 0 ||
          position > 604800 ||
          onPlay == null) {
        throw const FormatException();
      }
      final ref = title.routes[road].episodes[episode].url;
      if (source.id == 'nas-movies' &&
          parseNASMediaReference(ref)['nas'] != _namespace) {
        throw const FormatException();
      }
      // Return an acknowledgement before navigation. Only authenticated account
      // peers can reach this point; no NAS password/token crosses the LAN.
      request.response.statusCode = 200;
      request.response.write('accepted');
      await request.response.close();
      unawaited(onPlay!(title, source, road, episode, position));
    } catch (_) {
      request.response.statusCode = 403;
      await request.response.close();
    }
  }

  Future<void> discover() async {
    final current = await _nas.call('currentSession');
    if (current['namespace'] == null) {
      throw const FormatException('请先在手机和电视登录同一个 NAS 账号。');
    }
    televisions.clear();
    notifyListeners();
    await _channel.invokeMethod<void>('discover');
  }

  Future<void> send(
    Map<String, dynamic> target,
    CinemaTitle title,
    CinemaSource source,
    int road,
    int episode,
    int position,
  ) async {
    final current = await _nas.call('currentSession'),
        ns = current['namespace'];
    if (ns == null) throw const FormatException('请先登录 NAS。');
    final proof = await _nas.call('castSecret', {
      'namespace': ns,
      'id': target['id'],
    });
    final payload = await _secure.invokeMethod<String>('seal', {
      'key': proof['secret'],
      'text': jsonEncode({
        'namespace': ns,
        'nonce': _randomHex(),
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'title': title.toJson(),
        'source': source.toJson(),
        'road': road,
        'episode': episode,
        'position': position,
      }),
    });
    if (!CinemaAndroidNAS.privateIPv4('${target['host']}')) {
      throw const FormatException('电视不在局域网内。');
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final req = await client.postUrl(
        Uri(
          scheme: 'http',
          host: target['host'],
          port: target['port'],
          path: '/play',
        ),
      );
      req.followRedirects = false;
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({'payload': payload}));
      final response = await req.close().timeout(const Duration(seconds: 15));
      await response.drain<void>();
      if (response.statusCode != 200) {
        throw const FormatException('电视未接受播放请求，请检查两端的 NAS 账号。');
      }
    } finally {
      client.close(force: true);
    }
  }

  Future<void> stop() async {
    _generation++;
    _timer?.cancel();
    _timer = null;
    onPlay = null;
    await _server?.close(force: true);
    _server = null;
    if (Platform.isAndroid) await _channel.invokeMethod<void>('stop');
  }
}

Future<void> showCinemaCast(
  BuildContext context, {
  required CinemaTitle title,
  required CinemaSource source,
  int road = 0,
  int episode = 0,
  int position = 0,
}) async {
  final cast = CinemaLanCast.instance;
  try {
    await cast.discover();
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先在手机和电视登录同一个 NAS 账号，并连接同一局域网。')),
      );
    }
    return;
  }
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (context) => AnimatedBuilder(
      animation: cast,
      builder: (context, _) => AlertDialog(
        title: const Text('发送到电视'),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('电视需打开 NAKU，并登录同一个 NAS 账号。'),
              const SizedBox(height: 16),
              if (cast.televisions.isEmpty) const Text('正在发现局域网电视…'),
              for (final target in cast.televisions.values)
                ListTile(
                  leading: const Icon(Icons.tv),
                  title: const Text('NAKU 电视'),
                  subtitle: Text('${target['host']}'),
                  onTap: () async {
                    try {
                      await cast.send(
                        target,
                        title,
                        source,
                        road,
                        episode,
                        position,
                      );
                      if (context.mounted) {
                        Navigator.pop(context);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('已发送，电视将开始播放。')),
                        );
                      }
                    } catch (_) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('发送失败：请确认两端登录同一 NAS 账号，且电视接收服务已就绪。'),
                          ),
                        );
                      }
                    }
                  },
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    ),
  );
}
