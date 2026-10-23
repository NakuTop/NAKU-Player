import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_nas_media.dart';
import 'package:kazumi/features/cinema/cinema_nas_peer.dart';
import 'package:kazumi/features/cinema/cinema_sync_session.dart';

class _Library extends CinemaNASClient {
  bool allowed = true;
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic>? args,
  ]) async {
    if (!allowed) throw StateError('permission denied');
    if (method == 'catalog') {
      return {
        'video_arr': [_row],
      };
    }
    if (method == 'details') {
      return {
        'file_information': [
          {'path': '/movies/film.mkv', 'name': '原画'},
        ],
      };
    }
    return {};
  }
}

const _row = {
  'ug_video_info_id': 1,
  'media_lib_set_id': 2,
  'name': 'Test Film',
  'year': 2026,
  'type': 1,
};
void main() {
  test(
    'NAS follow resolves same work through viewer account without sharing resource references',
    () async {
      final host = createCinemaNASTitle(
        namespace: 'a' * 64,
        row: _row,
        files: [(label: '原画', path: '/private/host.mkv')],
      );
      final media = CinemaSyncMedia.fromSelection(
        host,
        host.routes.first.episodes.first,
      );
      final result = await resolveCinemaNASPeerPlayback(
        media: media,
        namespace: 'b' * 64,
        isCurrent: () => true,
        client: _Library(),
      );
      expect(result, isNotNull);
      final ref = parseNASMediaReference(result!.episode.url);
      expect(ref['nas'], 'b' * 64);
      expect(ref['path'], '/movies/film.mkv');
    },
  );
  test('NAS follow respects permissions and canceled navigation', () async {
    final host = createCinemaNASTitle(
      namespace: 'a' * 64,
      row: _row,
      files: [(label: '原画', path: '/host.mkv')],
    );
    final media = CinemaSyncMedia.fromSelection(
      host,
      host.routes.first.episodes.first,
    );
    expect(
      await resolveCinemaNASPeerPlayback(
        media: media,
        namespace: 'b' * 64,
        isCurrent: () => true,
        client: _Library()..allowed = false,
      ),
      isNull,
    );
    expect(
      await resolveCinemaNASPeerPlayback(
        media: media,
        namespace: 'b' * 64,
        isCurrent: () => false,
        client: _Library(),
      ),
      isNull,
    );
  });
}
