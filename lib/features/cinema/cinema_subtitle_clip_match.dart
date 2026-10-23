import 'dart:math' as math;
import 'dart:typed_data';
import 'cinema_external_subtitles.dart';
import 'cinema_subtitle_timing.dart';

class CinemaSubtitleClipMatch {
  const CinemaSubtitleClipMatch(this.timing, this.confidence, this.message);
  final CinemaSubtitleTiming? timing;
  final double confidence;
  final String message;
}

/// A five-second clip can identify a distinct pause pattern, or refine the
/// onset of a cue chosen by the viewer. It cannot identify spoken words.
CinemaSubtitleClipMatch matchCinemaSubtitleClip(
  List<CinemaSubtitleCue> cues,
  Uint8List voice, {
  required double startSeconds,
  required double positionSeconds,
  CinemaSubtitleTiming current = const CinemaSubtitleTiming(),
  CinemaSubtitleCue? anchor,
  int sampleSeconds = 5,
}) {
  final ambiguous = CinemaSubtitleClipMatch(
    null,
    0,
    '这 $sampleSeconds 秒无法唯一判断偏移；请在下方选中听到的对白，再点「按这句自动对齐」，或直接对齐当前画面',
  );
  final count = math.min(sampleSeconds.clamp(5, 20) * 50, voice.length);
  if (count < 100 || cues.isEmpty) return ambiguous;
  // Remove isolated VAD clicks and close tiny intra-word gaps.
  final bits = Uint8List.fromList(voice.take(count).toList());
  for (var i = 1; i + 1 < count; i++) {
    if (voice[i - 1] == voice[i + 1]) bits[i] = voice[i - 1];
  }
  final sum = bits.fold(0, (int a, int b) => a + b);
  if (sum < 15 || sum > count - 10) return ambiguous;
  if (anchor != null) {
    final runs = <({int start, int end})>[];
    for (var i = 0; i < count;) {
      if (bits[i] == 0) {
        i++;
        continue;
      }
      final begin = i;
      while (i < count && bits[i] == 1) {
        i++;
      }
      // A clipped phrase at the left boundary has no known onset.
      if (begin >= 6 &&
          i - begin >= 12 &&
          bits.sublist(begin - 6, begin).every((v) => v == 0)) {
        runs.add((start: begin, end: i));
      }
    }
    final at = (positionSeconds - startSeconds) * 50;
    final candidates = runs
        .where(
          (r) =>
              at >= r.start - 20 &&
              at <= r.end + 10 &&
              (at - r.start).abs() <= 100,
        )
        .toList();
    if (candidates.length != 1) return ambiguous;
    final onset = startSeconds + candidates.single.start * .02;
    final timing = current.align(
      subtitle: Duration(milliseconds: anchor.start),
      media: Duration(microseconds: (onset * 1000000).round()),
    );
    return CinemaSubtitleClipMatch(
      timing,
      .9,
      '已按选中对白的语音起点校准：偏移 ${timing.offsetSeconds.toStringAsFixed(2)} 秒（$sampleSeconds 秒本地分析）',
    );
  }
  var edges = 0;
  for (var i = 1; i < count; i++) {
    if (bits[i] != bits[i - 1]) edges++;
  }
  if (edges < 4) return ambiguous;
  // Build one subtitle mask for the bounded search range. Bilingual and
  // overlapping captions form a union rather than receiving double weight.
  const radius = 90.0, hz = 50;
  final base = startSeconds - current.offsetSeconds - radius;
  final template = Uint8List(count + (radius * 2 * hz).round() + 1);
  for (final cue in cues) {
    if (cue.end - cue.start > 12000 ||
        !RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(cue.text)) {
      continue;
    }
    final a = ((cue.start / 1000 * current.scale - base) * hz).round();
    final b = ((cue.end / 1000 * current.scale - base) * hz).round();
    if (b <= 0) continue;
    if (a >= template.length) break;
    template.fillRange(
      a.clamp(0, template.length),
      b.clamp(0, template.length),
      1,
    );
  }
  final prefix = List<int>.filled(template.length + 1, 0);
  for (var i = 0; i < template.length; i++) {
    prefix[i + 1] = prefix[i] + template[i];
  }
  final scores = <double>[];
  var best = -1.0, bestIndex = 0;
  final variance = sum - sum * sum / count;
  for (var step = 0; step <= radius * 2 * hz; step++) {
    final covered = prefix[step + count] - prefix[step];
    final cv = covered - covered * covered / count;
    var score = -1.0;
    if (cv > 5) {
      var joint = 0;
      for (var i = 0; i < count; i++) {
        joint += bits[i] * template[step + i];
      }
      score = (joint - sum * covered / count) / math.sqrt(variance * cv);
    }
    scores.add(score);
    if (score > best) {
      best = score;
      bestIndex = step;
    }
  }
  var competitor = -1.0;
  for (var i = 0; i < scores.length; i++) {
    if ((i - bestIndex).abs() > 40) {
      competitor = math.max(competitor, scores[i]);
    }
  }
  if (best < .72 ||
      best - competitor < .10 ||
      bestIndex < 10 ||
      bestIndex > scores.length - 11) {
    return ambiguous;
  }
  final offset = current.offsetSeconds + radius - bestIndex / hz;
  final timing = current.withOffset(offset);
  return CinemaSubtitleClipMatch(
    timing,
    best,
    (offset - current.offsetSeconds).abs() <= .15
        ? '这 $sampleSeconds 秒对白与当前字幕已对齐，保留现有时间轴'
        : '$sampleSeconds 秒对白匹配完成：偏移 ${offset.toStringAsFixed(2)} 秒，保留时间轴倍率',
  );
}

class CinemaSpokenWord {
  const CinemaSpokenWord(this.text, this.start, this.end, this.confidence);
  final String text;
  final double start, end, confidence;
}

/// Prefer an informative nearby dialogue boundary before requesting audio.
/// The main player is never sought. Only one five-second sample is decoded.
double cinemaSubtitleDialogueStart(
  List<CinemaSubtitleCue> cues, {
  required double position,
  required double duration,
  int sampleSeconds = 5,
  CinemaSubtitleTiming timing = const CinemaSubtitleTiming(),
}) {
  final fallback = (position - 2).floorToDouble().clamp(
    0.0,
    math.max(0.0, duration - sampleSeconds),
  );
  var best = fallback.toDouble(), score = double.negativeInfinity;
  for (final cue in cues) {
    final onset = cue.start / 1000 * timing.scale + timing.offsetSeconds;
    if ((onset - position).abs() > 30 ||
        onset < .3 ||
        onset + sampleSeconds - .4 > duration) {
      continue;
    }
    final start = onset - .4;
    final words = <String>{};
    var boundaries = 0;
    for (final c in cues) {
      final at = c.start / 1000 * timing.scale + timing.offsetSeconds;
      if (at < start || at > start + sampleSeconds - .8) continue;
      final latin = _words(c.text, false);
      final tokens = latin.length >= 3 ? latin : _words(c.text, true);
      words.addAll(tokens);
      boundaries++;
    }
    if (words.length < 6) continue;
    final quality =
        math.min(words.length, 18) +
        math.min(boundaries, 3) * 2 -
        (onset - position).abs() * .3;
    if (quality > score) {
      score = quality;
      best = start;
    }
  }
  return best;
}

List<String> _words(String text, bool chinese) => chinese
    ? RegExp(r'[\u3400-\u9fff]').allMatches(text).map((m) => m[0]!).toList()
    : RegExp(r"[a-z0-9]+(?:'[a-z]+)?")
          .allMatches(text.toLowerCase().replaceAll('’', "'"))
          .map((m) => m[0]!.replaceAll("'", ''))
          .toList();

/// Locate recognized words in the existing subtitle. Local sequence alignment
/// tolerates missed or misheard words; repeated phrases need a unique winner.
/// Only a matched cue's first word can anchor a time, never an estimated word
/// position inside a translated sentence.
CinemaSubtitleClipMatch matchCinemaSubtitleWords(
  List<CinemaSubtitleCue> cues,
  List<CinemaSpokenWord> words, {
  required double startSeconds,
  CinemaSubtitleTiming current = const CinemaSubtitleTiming(),
  Uint8List? speech,
  int sampleSeconds = 5,
}) {
  const rejected = CinemaSubtitleClipMatch(
    null,
    0,
    '未找到唯一对应的字幕对白，保留原对齐；可选择听到的一句进行校准',
  );
  final text = words.map((w) => w.text).join(' ');
  final chinese =
      RegExp(r'[\u3400-\u9fff]').allMatches(text).length >
      RegExp(r'[a-zA-Z]').allMatches(text).length;
  final spoken = <({String word, double start})>[];
  for (final w in words) {
    if (!w.start.isFinite ||
        !w.end.isFinite ||
        w.start < 0 ||
        w.end > sampleSeconds + .2 ||
        w.end <= w.start ||
        w.confidence < .25) {
      continue;
    }
    final tokens = _words(w.text, chinese);
    var onset = w.start;
    // Apple may assign the preceding pause to the first word of each phrase.
    // Refine only when VAD independently confirms that pause inside the range.
    if (speech != null) {
      final begin = (w.start * 50).floor().clamp(0, speech.length);
      final limit = math.min(speech.length - 7, (w.end * 50).ceil());
      for (var frame = begin + 6; frame <= limit; frame++) {
        if (speech.skip(begin).take(frame - begin).every((v) => v == 0) &&
            speech.skip(frame).take(7).where((v) => v == 1).length >= 6) {
          onset = frame * .02;
          break;
        }
      }
    }
    for (var i = 0; i < tokens.length; i++) {
      spoken.add((
        word: tokens[i],
        start: onset + (w.end - onset) * i / tokens.length,
      ));
    }
  }
  final minimum = chinese ? 6 : 4;
  if (spoken.length < minimum || spoken.length > sampleSeconds * 20) {
    return rejected;
  }
  final tokenized = [for (final cue in cues) _words(cue.text, chinese)];
  final candidates = <({double offset, double quality, int matches})>[];
  for (var c = 0; c < cues.length; c++) {
    final caption = <({String word, int cue, int index})>[];
    for (var k = c; k < math.min(c + sampleSeconds * 2, cues.length); k++) {
      if (cues[k].start - cues[c].start > (sampleSeconds + 2) * 1000) break;
      for (
        var i = 0;
        i < tokenized[k].length && caption.length < sampleSeconds * 16;
        i++
      ) {
        caption.add((word: tokenized[k][i], cue: k, index: i));
      }
    }
    if (caption.length < minimum) continue;
    final scores = List.generate(
      spoken.length + 1,
      (_) => List<int>.filled(caption.length + 1, 0),
    );
    var best = 0, bi = 0, bj = 0;
    for (var i = 1; i <= spoken.length; i++) {
      for (var j = 1; j <= caption.length; j++) {
        final equal = spoken[i - 1].word == caption[j - 1].word;
        final value = math.max(
          0,
          math.max(
            scores[i - 1][j - 1] + (equal ? 3 : -2),
            math.max(scores[i - 1][j] - 2, scores[i][j - 1] - 2),
          ),
        );
        scores[i][j] = value;
        if (value > best) {
          best = value;
          bi = i;
          bj = j;
        }
      }
    }
    final pairs = <(int, int)>[];
    var i = bi, j = bj;
    while (i > 0 && j > 0 && scores[i][j] > 0) {
      final equal = spoken[i - 1].word == caption[j - 1].word;
      if (scores[i][j] == scores[i - 1][j - 1] + (equal ? 3 : -2)) {
        if (equal) pairs.add((i - 1, j - 1));
        i--;
        j--;
      } else if (scores[i][j] == scores[i - 1][j] - 2) {
        i--;
      } else {
        j--;
      }
    }
    if (pairs.length < minimum ||
        pairs.length / spoken.length < .6 ||
        pairs.map((p) => spoken[p.$1].word).toSet().length <
            (chinese ? 4 : 3)) {
      continue;
    }
    for (final pair in pairs) {
      final token = caption[pair.$2];
      // A word clipped at the recording boundary has no reliable onset.
      if (token.index != 0 ||
          spoken[pair.$1].start < .12 ||
          tokenized[token.cue].length < 2 ||
          !pairs.any(
            (p) =>
                caption[p.$2].cue == token.cue &&
                caption[p.$2].index == 1 &&
                p.$1 > pair.$1 &&
                p.$1 <= pair.$1 + 2,
          )) {
        continue;
      }
      final offset =
          startSeconds +
          spoken[pair.$1].start -
          cues[token.cue].start / 1000 * current.scale;
      if ((offset - current.offsetSeconds).abs() > 180) continue;
      candidates.add((
        offset: offset,
        quality: best / (3 * spoken.length),
        matches: pairs.length,
      ));
    }
  }
  if (candidates.isEmpty) return rejected;
  candidates.sort((a, b) => b.quality.compareTo(a.quality));
  final best = candidates.first;
  if (best.quality < .5 ||
      candidates.any(
        (c) =>
            (c.offset - best.offset).abs() > 1.2 &&
            best.quality - c.quality < .15,
      )) {
    return rejected;
  }
  final offsets =
      candidates
          .where(
            (c) =>
                (c.offset - best.offset).abs() <= .6 &&
                best.quality - c.quality < .05,
          )
          .map((c) => c.offset)
          .toList()
        ..sort();
  final offset = offsets[offsets.length ~/ 2];
  return CinemaSubtitleClipMatch(
    current.withOffset(offset),
    best.quality,
    '已用 $sampleSeconds 秒对白文字定位字幕：偏移 ${offset.toStringAsFixed(2)} 秒（Mac 本地识别）',
  );
}
