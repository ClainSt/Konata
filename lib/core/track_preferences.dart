import 'package:media_kit/media_kit.dart';

enum SubtitleLanguage { simplified, traditional, japanese, chinese, unknown }

abstract final class TrackPreferences {
  static SubtitleLanguage subtitleLanguage(String? language, String? title) {
    final text = '${language ?? ''} ${title ?? ''}'.toLowerCase().replaceAll(
      '_',
      '-',
    );
    bool has(String pattern) =>
        RegExp(pattern, caseSensitive: false).hasMatch(text);
    if (has(
      r'简体|简中|简日|簡體|簡中|簡日|simplified|zh[-_]?(cn|sg|hans)|\b(chs|sc|gb)\b',
    )) {
      return SubtitleLanguage.simplified;
    }
    if (has(
      r'繁体|繁中|繁日|繁體|traditional|zh[-_]?(tw|hk|mo|hant)|\b(cht|tc|big5)\b',
    )) {
      return SubtitleLanguage.traditional;
    }
    if (has(r'\b(zh|zho|chi|chinese)\b|中文|中日')) return SubtitleLanguage.chinese;
    if (has(r'\b(ja|jp|jpn|japanese)\b|日语|日語|日本語')) {
      return SubtitleLanguage.japanese;
    }
    return SubtitleLanguage.unknown;
  }

  static bool lossless(AudioTrack track) {
    final codec = (track.codec ?? '').toLowerCase();
    final text = '$codec ${track.title ?? ''}'.toLowerCase();
    return RegExp(
          r'^(flac|alac|truehd|mlp|wavpack|ape|tta|tak|wmalossless|pcm(?:_|$))',
        ).hasMatch(codec) ||
        RegExp(
          r'truehd|dts[- _]?hd\s*(ma|master)|dts_hd_ma|\b(flac|alac|lossless)\b|无损|無損',
        ).hasMatch(text);
  }

  static SubtitleTrack? subtitle(Iterable<SubtitleTrack> tracks) {
    final real = tracks.where((t) => t.id != 'auto' && t.id != 'no').toList();
    int score(SubtitleTrack t) =>
        switch (subtitleLanguage(t.language, t.title)) {
          SubtitleLanguage.simplified => 100,
          SubtitleLanguage.chinese => 70,
          SubtitleLanguage.traditional => 60,
          SubtitleLanguage.japanese => 40,
          SubtitleLanguage.unknown => 20,
        } +
        (t.isDefault == true ? 1 : 0);
    SubtitleTrack? best;
    for (final track in real) {
      if (best == null || score(track) > score(best)) best = track;
    }
    return best;
  }

  static AudioTrack? audio(
    Iterable<AudioTrack> tracks, {
    Set<String>? supportedCodecs,
  }) {
    var candidates = tracks
        .where(
          (t) =>
              t.id != 'auto' &&
              t.id != 'no' &&
              (supportedCodecs == null ||
                  t.codec == null ||
                  t.codec!.isEmpty ||
                  supportedCodecs.contains(t.codec!.toLowerCase())),
        )
        .toList();
    if (candidates.isEmpty) return null;
    final mainTracks = candidates
        .where(
          (t) => !RegExp(
            r'commentary|评论|評論|解说|解說',
            caseSensitive: false,
          ).hasMatch(t.title ?? ''),
        )
        .toList();
    if (mainTracks.isNotEmpty) candidates = mainTracks;
    // Quality is compared only among the same language/content when known.
    // Container defaults determine the language; lossless must not override it.
    final primary = candidates.firstWhere(
      (t) => t.isDefault == true,
      orElse: () => candidates.first,
    );
    String language(AudioTrack t) => switch ((t.language ?? '')
        .toLowerCase()
        .replaceAll('_', '-')
        .split('-')
        .first) {
      'ja' || 'jp' || 'jpn' => 'jpn',
      'zh' || 'zho' || 'chi' => 'zho',
      'en' || 'eng' => 'eng',
      final other => other,
    };
    if (language(primary).isNotEmpty && language(primary) != 'und') {
      candidates = candidates
          .where((t) => language(t) == language(primary))
          .toList();
    }
    AudioTrack? best;
    int score(AudioTrack t) =>
        (lossless(t) ? 100 : 0) + (t.isDefault == true ? 5 : 0);
    for (final track in candidates) {
      if (best == null || score(track) > score(best)) best = track;
    }
    return best;
  }
}
