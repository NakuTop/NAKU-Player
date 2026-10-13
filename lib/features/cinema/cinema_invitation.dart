import 'dart:async';
import 'dart:convert';
import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:kazumi/services/player/syncplay_endpoint.dart';
import 'cinema_sync_session.dart';

/// Metadata only; recipients use their own catalogue. Never share a media URL,
/// request headers, credentials, local paths or the sender's identity.
class CinemaInvitation {
  const CinemaInvitation({
    required this.media,
    this.positionSeconds = 0,
    this.endpoint = '',
    this.room = '',
    this.animeId,
  });
  final CinemaSyncMedia? media;
  final int positionSeconds;
  final String endpoint, room;
  final int? animeId;
  bool get hasRoom => endpoint.isNotEmpty && room.isNotEmpty;
  String encode() => Uri(
    scheme: 'naku',
    host: 'watch',
    queryParameters: {
      'v': '2',
      'data': base64Url
          .encode(
            utf8.encode(
              jsonEncode({
                'media': media?.toJson(),
                'position': positionSeconds,
                if (hasRoom) 'endpoint': endpoint,
                if (hasRoom) 'room': room,
                if (animeId != null) 'animeId': animeId,
              }),
            ),
          )
          .replaceAll('=', ''),
    },
  ).toString();
  static CinemaInvitation parse(String text) {
    if (text.length > 4096) throw const FormatException('邀请链接过长');
    final uri = Uri.parse(text.trim());
    if (uri.scheme != 'naku' ||
        uri.host != 'watch' ||
        uri.queryParameters['v'] != '2') {
      throw const FormatException('需要 NAKU 2.0 邀请链接');
    }
    final raw = jsonDecode(
      utf8.decode(
        base64Url.decode(
          base64Url.normalize(uri.queryParameters['data'] ?? ''),
        ),
      ),
    );
    if (raw is! Map ||
        raw['position'] is! int ||
        raw['position'] < 0 ||
        raw['position'] > 86400) {
      throw const FormatException('邀请内容无效');
    }
    final media = raw['media'] == null
        ? null
        : CinemaSyncMedia.fromJson(raw['media']);
    if (raw['media'] != null && media == null) {
      throw const FormatException('邀请作品无效');
    }
    final endpoint = '${raw['endpoint'] ?? ''}', room = '${raw['room'] ?? ''}';
    if ((endpoint.isEmpty != room.isEmpty) ||
        (endpoint.isNotEmpty &&
            (parseSyncPlayEndPoint(endpoint) == null ||
                room.length > 35 ||
                RegExp(r'[\x00-\x1f\x7f]').hasMatch(room)))) {
      throw const FormatException('房间信息无效');
    }
    final anime = raw['animeId'];
    if (anime != null && (anime is! int || anime < 1 || anime > 10000000)) {
      throw const FormatException('动漫编号无效');
    }
    if (media == null && endpoint.isEmpty && anime == null) {
      throw const FormatException('邀请为空');
    }
    return CinemaInvitation(
      media: media,
      positionSeconds: raw['position'],
      endpoint: endpoint,
      room: room,
      animeId: anime,
    );
  }
}

class CinemaInvitationInbox extends ValueNotifier<CinemaInvitation?> {
  CinemaInvitationInbox() : super(null);
  static final instance = CinemaInvitationInbox();
  StreamSubscription<Uri>? _subscription;
  final _recent = <String, DateTime>{};
  Future<void> start() async {
    if (_subscription != null) return;
    try {
      final appLinks = AppLinks();
      _subscription = appLinks.uriLinkStream.listen((uri) {
        try {
          final text = uri.toString();
          final now = DateTime.now();
          _recent.removeWhere((_, at) => now.difference(at).inSeconds >= 2);
          if (_recent.containsKey(text)) return;
          _recent[text] = now;
          value = CinemaInvitation.parse(text);
        } catch (_) {
          /* Unknown OS links never execute commands. */
        }
      }, onError: (Object _) {});
    } catch (_) {
      /* Paste-to-open is available on platforms without URL registration. */
    }
  }

  void receive(String text) => value = CinemaInvitation.parse(text);
}

Future<void> showCinemaInvitation(
  BuildContext context,
  CinemaInvitation invite,
) => showDialog<void>(
  context: context,
  builder: (context) {
    final link = invite.encode();
    return AlertDialog(
      title: const Text('邀请一起观看'),
      content: SizedBox(
        width: 430,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (invite.media != null)
                Text('${invite.media!.title} · ${invite.media!.episodeName}'),
              const SizedBox(height: 16),
              QrImageView(
                data: link,
                size: 260,
                backgroundColor: Colors.white,
                errorCorrectionLevel: QrErrorCorrectLevel.M,
              ),
              const SizedBox(height: 12),
              SelectableText(
                link,
                maxLines: 5,
                style: const TextStyle(fontSize: 11),
              ),
              const SizedBox(height: 12),
              Text(
                invite.hasRoom
                    ? '含房间信息。对方打开链接并确认后，会用自己的片源播放；双方需使用 NAKU 2.0。'
                    : '对方打开链接并确认后，会用自己的片源打开此作品和进度。',
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
        FilledButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: link));
            if (context.mounted) {
              ScaffoldMessenger.maybeOf(
                context,
              )?.showSnackBar(const SnackBar(content: Text('邀请链接已复制')));
            }
          },
          icon: const Icon(Icons.copy),
          label: const Text('复制链接'),
        ),
      ],
    );
  },
);

Future<void> pasteCinemaInvitation(BuildContext context) async {
  final controller = TextEditingController();
  final text = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('打开邀请链接'),
      content: SizedBox(
        width: 480,
        child: TextField(
          controller: controller,
          maxLines: 5,
          decoration: const InputDecoration(hintText: '粘贴 naku://watch 邀请链接'),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text),
          child: const Text('打开'),
        ),
      ],
    ),
  );
  controller.dispose();
  if (text != null && context.mounted) {
    try {
      CinemaInvitationInbox.instance.receive(text);
    } catch (_) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text('邀请链接无效')));
    }
  }
}
