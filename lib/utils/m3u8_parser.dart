class M3u8Key {
  final String method;
  final String uri;
  final String? iv;

  M3u8Key({required this.method, required this.uri, this.iv});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is M3u8Key &&
          method == other.method &&
          uri == other.uri &&
          iv == other.iv;

  @override
  int get hashCode => Object.hash(method, uri, iv);

  @override
  String toString() {
    final sb = StringBuffer('#EXT-X-KEY:METHOD=$method,URI="$uri"');
    if (iv != null) {
      sb.write(',IV=$iv');
    }
    return sb.toString();
  }
}

class M3u8ByteRange {
  const M3u8ByteRange(this.length, this.offset);
  final int length, offset;
  String get header => 'bytes=$offset-${offset + length - 1}';
  String get identity => '$length@$offset';
}

class M3u8Segment {
  final double duration;
  final String uri;
  final int discontinuityGroup;
  final M3u8Key? key;
  final M3u8ByteRange? byteRange, initializationRange;
  final String? initializationUri;
  final int sequence;
  String? get initializationIdentity => initializationUri == null
      ? null
      : '$initializationUri|${initializationRange?.identity ?? ''}';

  M3u8Segment({
    required this.duration,
    required this.uri,
    required this.discontinuityGroup,
    this.key,
    this.byteRange,
    this.initializationUri,
    this.initializationRange,
    this.sequence = 0,
  });
}

class M3u8Variant {
  final int bandwidth;
  final String? resolution;
  final String uri;
  final String? audioGroup;

  M3u8Variant({
    required this.bandwidth,
    this.resolution,
    required this.uri,
    this.audioGroup,
  });
}

class M3u8AudioRendition {
  const M3u8AudioRendition(this.group, this.uri, this.isDefault);
  final String group, uri;
  final bool isDefault;
}

class M3u8MasterPlaylist {
  final List<M3u8Variant> variants;
  final List<M3u8AudioRendition> audio;

  M3u8MasterPlaylist({required this.variants, this.audio = const []});

  M3u8Variant get bestVariant {
    if (variants.isEmpty) throw const FormatException('播放列表中没有可下载的视频');
    return variants.reduce((a, b) => a.bandwidth > b.bandwidth ? a : b);
  }
}

class M3u8MediaPlaylist {
  final List<M3u8Segment> segments;
  final double targetDuration;
  final bool isVod;

  M3u8MediaPlaylist({
    required this.segments,
    required this.targetDuration,
    required this.isVod,
  });
}

enum M3u8Type { master, media }

class M3u8Parser {
  static M3u8Type detectType(String content) {
    if (content.contains('#EXT-X-STREAM-INF')) {
      return M3u8Type.master;
    }
    return M3u8Type.media;
  }

  static String resolveUrl(String baseUrl, String relativeUrl) {
    final result = Uri.parse(baseUrl).resolve(relativeUrl);
    if (!['http', 'https'].contains(result.scheme) ||
        result.host.isEmpty ||
        result.userInfo.isNotEmpty) {
      throw const FormatException('播放列表包含不支持的下载地址');
    }
    return result.toString();
  }

  static M3u8MasterPlaylist parseMasterPlaylist(
    String content,
    String baseUrl,
  ) {
    final lines = content.split('\n').map((l) => l.trim()).toList();
    final variants = <M3u8Variant>[];
    final audio = <M3u8AudioRendition>[];

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.startsWith('#EXT-X-MEDIA:')) {
        final attrs = _attributes(line);
        if (attrs['TYPE'] == 'AUDIO' && attrs['URI'] != null) {
          audio.add(
            M3u8AudioRendition(
              attrs['GROUP-ID'] ?? '',
              resolveUrl(baseUrl, attrs['URI']!),
              attrs['DEFAULT'] == 'YES',
            ),
          );
        }
      }
      if (line.startsWith('#EXT-X-STREAM-INF:')) {
        final attrs = line.substring('#EXT-X-STREAM-INF:'.length);
        int bandwidth = 0;
        String? resolution;

        final bandwidthMatch = RegExp(r'BANDWIDTH=(\d+)').firstMatch(attrs);
        if (bandwidthMatch != null) {
          bandwidth = int.parse(bandwidthMatch.group(1)!);
        }

        final resolutionMatch = RegExp(
          r'RESOLUTION=([^\s,]+)',
        ).firstMatch(attrs);
        if (resolutionMatch != null) {
          resolution = resolutionMatch.group(1);
        }

        if (i + 1 < lines.length && !lines[i + 1].startsWith('#')) {
          final uri = resolveUrl(baseUrl, lines[i + 1]);
          variants.add(
            M3u8Variant(
              bandwidth: bandwidth,
              resolution: resolution,
              uri: uri,
              audioGroup: _attributes(line)['AUDIO'],
            ),
          );
        }
      }
    }

    return M3u8MasterPlaylist(variants: variants, audio: audio);
  }

  static Map<String, String> _attributes(String line) => {
    for (final m in RegExp(
      r'([A-Z0-9-]+)=(?:"([^"]*)"|([^,]*))',
    ).allMatches(line))
      m.group(1)!: m.group(2) ?? m.group(3) ?? '',
  };

  static M3u8ByteRange _range(String value, int implicitOffset) {
    final parts = value.split('@');
    final length = int.tryParse(parts.first);
    final offset = parts.length == 2 ? int.tryParse(parts[1]) : implicitOffset;
    if (length == null || length <= 0 || offset == null || offset < 0) {
      throw const FormatException('无效的视频分段字节范围');
    }
    return M3u8ByteRange(length, offset);
  }

  static M3u8MediaPlaylist parseMediaPlaylist(String content, String baseUrl) {
    final lines = content.split('\n').map((l) => l.trim()).toList();
    final segments = <M3u8Segment>[];
    double targetDuration = 0;
    bool hasEndList = false;
    bool isExplicitVod = false;
    bool isLiveEvent = false;
    int currentDiscontinuityGroup = 0;
    M3u8Key? currentKey;
    double currentDuration = 0;
    int sequence = 0, nextOffset = 0;
    String? rangeText, initializationUri, previousRangeUri;
    M3u8ByteRange? initializationRange;

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];

      if (line.startsWith('#EXT-X-MEDIA-SEQUENCE:')) {
        sequence = int.parse(line.split(':').last);
        if (sequence < 0) throw const FormatException('无效的视频分片序号');
      } else if (line.startsWith('#EXT-X-BYTERANGE:')) {
        rangeText = line.split(':').last;
      } else if (line.startsWith('#EXT-X-MAP:')) {
        final attrs = _attributes(line);
        if (attrs['URI'] == null) throw const FormatException('缺少视频初始化分片');
        initializationUri = resolveUrl(baseUrl, attrs['URI']!);
        initializationRange = attrs['BYTERANGE'] == null
            ? null
            : _range(attrs['BYTERANGE']!, 0);
      } else if (line.startsWith('#EXT-X-TARGETDURATION:')) {
        targetDuration = double.parse(
          line.substring('#EXT-X-TARGETDURATION:'.length),
        );
      } else if (line == '#EXT-X-ENDLIST') {
        hasEndList = true;
      } else if (line == '#EXT-X-PLAYLIST-TYPE:VOD') {
        isExplicitVod = true;
      } else if (line == '#EXT-X-PLAYLIST-TYPE:EVENT') {
        isLiveEvent = true;
      } else if (line == '#EXT-X-DISCONTINUITY') {
        currentDiscontinuityGroup++;
      } else if (line.startsWith('#EXT-X-KEY:')) {
        currentKey = _parseKey(line, baseUrl);
      } else if (line.startsWith('#EXTINF:')) {
        final durationStr = line.substring('#EXTINF:'.length).split(',')[0];
        currentDuration = double.parse(durationStr);
      } else if (line.isNotEmpty && !line.startsWith('#')) {
        final uri = resolveUrl(baseUrl, line);
        if (rangeText != null &&
            !rangeText.contains('@') &&
            previousRangeUri != uri) {
          throw const FormatException('视频分段缺少起始字节位置');
        }
        final range = rangeText == null ? null : _range(rangeText, nextOffset);
        nextOffset = range == null ? 0 : range.offset + range.length;
        previousRangeUri = range == null ? null : uri;
        segments.add(
          M3u8Segment(
            duration: currentDuration,
            uri: uri,
            discontinuityGroup: currentDiscontinuityGroup,
            key: currentKey,
            byteRange: range,
            initializationUri: initializationUri,
            initializationRange: initializationRange,
            sequence: sequence++,
          ),
        );
        rangeText = null;
        currentDuration = 0;
      }
    }

    // Consider it VOD if:
    // 1. Has #EXT-X-ENDLIST, or
    // 2. Has #EXT-X-PLAYLIST-TYPE:VOD, or
    // 3. Has finite segments and is not explicitly a live EVENT stream.
    // Many third-party video sources omit #EXT-X-ENDLIST for VOD content.
    final bool isVod =
        hasEndList || isExplicitVod || (!isLiveEvent && segments.isNotEmpty);

    return M3u8MediaPlaylist(
      segments: segments,
      targetDuration: targetDuration,
      isVod: isVod,
    );
  }

  static M3u8Key? _parseKey(String line, String baseUrl) {
    final attrs = line.substring('#EXT-X-KEY:'.length);

    final methodMatch = RegExp(r'METHOD=([^,]+)').firstMatch(attrs);
    final method = methodMatch?.group(1) ?? 'NONE';

    if (method == 'NONE') return null;
    final keyFormat = _attributes(line)['KEYFORMAT'];
    if (method != 'AES-128' || (keyFormat != null && keyFormat != 'identity')) {
      throw const FormatException('此片源使用受保护的加密格式，无法离线保存');
    }

    final uriMatch = RegExp(r'URI="([^"]+)"').firstMatch(attrs);
    if (uriMatch == null) throw const FormatException('缺少视频解密密钥地址');
    final uri = resolveUrl(baseUrl, uriMatch.group(1)!);

    final ivMatch = RegExp(r'IV=(0x[0-9a-fA-F]+)').firstMatch(attrs);
    final iv = ivMatch?.group(1);

    return M3u8Key(method: method, uri: uri, iv: iv);
  }

  static List<M3u8Key> extractUniqueKeys(M3u8MediaPlaylist playlist) {
    final seen = <String>{};
    final keys = <M3u8Key>[];
    for (final seg in playlist.segments) {
      if (seg.key != null && !seen.contains(seg.key!.uri)) {
        seen.add(seg.key!.uri);
        keys.add(seg.key!);
      }
    }
    return keys;
  }

  static String buildLocalM3u8(
    List<M3u8Segment> segments, {
    required double targetDuration,
    Map<String, String> keyUriToLocal = const {},
    Map<String, String> initializationToLocal = const {},
  }) {
    final sb = StringBuffer();
    sb.writeln('#EXTM3U');
    sb.writeln(
      '#EXT-X-VERSION:${segments.any((s) => s.initializationUri != null) ? 7 : 3}',
    );
    sb.writeln('#EXT-X-TARGETDURATION:${targetDuration.ceil()}');
    sb.writeln('#EXT-X-MEDIA-SEQUENCE:0');

    int lastDiscontinuityGroup = 0;
    M3u8Key? lastKey;
    String? lastInitialization;

    for (int i = 0; i < segments.length; i++) {
      final seg = segments[i];

      if (seg.discontinuityGroup != lastDiscontinuityGroup && i > 0) {
        sb.writeln('#EXT-X-DISCONTINUITY');
        lastDiscontinuityGroup = seg.discontinuityGroup;
      }

      if (seg.key != lastKey || (seg.key != null && seg.key!.iv == null)) {
        if (seg.key == null) {
          sb.writeln('#EXT-X-KEY:METHOD=NONE');
        } else {
          final localUri = keyUriToLocal[seg.key!.uri] ?? seg.key!.uri;
          final keySb = StringBuffer(
            '#EXT-X-KEY:METHOD=${seg.key!.method},URI="$localUri"',
          );
          if (seg.key!.iv != null) {
            keySb.write(',IV=${seg.key!.iv}');
          } else {
            keySb.write(
              ',IV=0x${seg.sequence.toRadixString(16).padLeft(32, '0')}',
            );
          }
          sb.writeln(keySb.toString());
        }
        lastKey = seg.key;
      }

      if (seg.initializationIdentity != null &&
          seg.initializationIdentity != lastInitialization) {
        final local = initializationToLocal[seg.initializationIdentity];
        if (local == null) throw const FormatException('视频初始化分片尚未保存');
        sb.writeln('#EXT-X-MAP:URI="$local"');
        lastInitialization = seg.initializationIdentity;
      }

      sb.writeln('#EXTINF:${seg.duration.toStringAsFixed(6)},');
      sb.writeln('seg_${i.toString().padLeft(5, '0')}.ts');
    }

    sb.writeln('#EXT-X-ENDLIST');
    return sb.toString();
  }

  static bool _isM3u8Url(String url) {
    final path = Uri.parse(url).path.toLowerCase();
    return path.endsWith('.m3u8');
  }

  /// 展开嵌套 M3U8 片段。
  /// [fetcher] 异步回调，给定 URL 返回 M3U8 文本内容。
  /// [maxDepth] 递归深度上限，防止无限嵌套。
  static Future<List<M3u8Segment>> resolveNestedSegments(
    List<M3u8Segment> segments,
    Future<String> Function(String url) fetcher, {
    int maxDepth = 3,
  }) async {
    if (!segments.any((s) => _isM3u8Url(s.uri))) return segments;
    if (maxDepth <= 0) throw const FormatException('视频播放列表嵌套过深');

    final result = <M3u8Segment>[];
    int groupOffset = 0;

    for (final seg in segments) {
      if (!_isM3u8Url(seg.uri)) {
        result.add(
          M3u8Segment(
            duration: seg.duration,
            uri: seg.uri,
            discontinuityGroup: seg.discontinuityGroup + groupOffset,
            key: seg.key,
            byteRange: seg.byteRange,
            initializationUri: seg.initializationUri,
            initializationRange: seg.initializationRange,
            sequence: seg.sequence,
          ),
        );
        continue;
      }

      // 该 segment 的 URI 指向嵌套 m3u8，展开
      {
        final content = await fetcher(seg.uri);
        final nested = parseMediaPlaylist(content, seg.uri);
        final resolved = await resolveNestedSegments(
          nested.segments,
          fetcher,
          maxDepth: maxDepth - 1,
        );

        if (resolved.isEmpty) throw const FormatException('嵌套播放列表中没有视频分片');

        final nestedBase = seg.discontinuityGroup + groupOffset;
        int maxNestedGroup = 0;
        for (final ns in resolved) {
          if (ns.discontinuityGroup > maxNestedGroup) {
            maxNestedGroup = ns.discontinuityGroup;
          }
        }

        for (final ns in resolved) {
          result.add(
            M3u8Segment(
              duration: ns.duration,
              uri: ns.uri,
              discontinuityGroup: ns.discontinuityGroup + nestedBase,
              key: ns.key,
              byteRange: ns.byteRange,
              initializationUri: ns.initializationUri,
              initializationRange: ns.initializationRange,
              sequence: ns.sequence,
            ),
          );
        }

        // 后续 segment 的 group 需要额外偏移，避免碰撞
        groupOffset += maxNestedGroup;
      }
    }

    return result;
  }
}
