import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'cinema_models.dart';

CinemaTitle createCinemaDirectMedia(String address, {String name = ''}) {
  if (address.contains(RegExp(r'[\r\n]'))) {
    throw const FormatException('请只填写一个完整的视频直链');
  }
  final uri = requireHttpUrl(address);
  // Display a user label, never a signed URL or its query credentials.
  final label = name.trim().isEmpty ? '我的直链视频' : name.trim();
  if (label.length > 120) throw const FormatException('名称最多 120 个字符');
  return CinemaTitle(
    id: sha256.convert(utf8.encode(uri.toString())).toString(),
    sourceId: cinemaDirectSource.id,
    title: label,
    category: '直链',
    routes: [
      CinemaRoute(
        name: '直链',
        episodes: [CinemaEpisode(name: '播放', url: uri.toString())],
      ),
    ],
  );
}

Future<({CinemaTitle title, bool favorite})?> showCinemaDirectMediaDialog(
  BuildContext context,
) => showDialog<({CinemaTitle title, bool favorite})>(
  context: context,
  builder: (_) => const _DirectMediaDialog(),
);

class _DirectMediaDialog extends StatefulWidget {
  const _DirectMediaDialog();
  @override
  State<_DirectMediaDialog> createState() => _DirectMediaDialogState();
}

class _DirectMediaDialogState extends State<_DirectMediaDialog> {
  final _url = TextEditingController(), _name = TextEditingController();
  String? _error;
  @override
  void dispose() {
    _url.dispose();
    _name.dispose();
    super.dispose();
  }

  void _open(bool favorite) {
    try {
      final title = createCinemaDirectMedia(_url.text, name: _name.text);
      Navigator.pop(context, (title: title, favorite: favorite));
    } on FormatException catch (error) {
      setState(() => _error = error.message);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('打开高清直链'),
    content: SizedBox(
      width: 560,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '支持 HLS、MP4、MKV 等 HTTP / HTTPS 视频地址。实际清晰度与帧率取决于原视频；播放后可在「画质信息」查看。',
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _url,
              autofocus: true,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                labelText: '视频直链',
                hintText: 'https://…/master.m3u8',
                errorText: _error,
              ),
              onSubmitted: (_) => _open(false),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _name,
              maxLength: 120,
              decoration: const InputDecoration(
                labelText: '名称（可选）',
                hintText: '用于收藏和继续观看',
              ),
            ),
            const SizedBox(height: 8),
            const Text('带有效期的链接过期后需要重新添加。网页地址需要从「网页影院」打开。'),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      OutlinedButton(onPressed: () => _open(false), child: const Text('播放')),
      FilledButton(onPressed: () => _open(true), child: const Text('收藏并播放')),
    ],
  );
}
