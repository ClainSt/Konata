import 'package:path/path.dart' as p;

/// Filename hints, never a substitute for probed stream metadata.
/// Raw names remain in assets; no file is read, renamed, or merged here.
class MediaVersion {
  MediaVersion._({
    required this.releaseTags,
    required this.encoderTags,
    required this.subtitleGroups,
    required this.resolution,
    required this.videoCodecs,
    required this.bitDepth,
    required this.hdrFormats,
    required this.audioCodecs,
    required this.subtitleHints,
  });

  final List<String> releaseTags, encoderTags, subtitleGroups;
  final String? resolution, bitDepth;
  final List<String> videoCodecs, hdrFormats, audioCodecs, subtitleHints;

  static MediaVersion parse(String filename) {
    final name = p.posix.basename(filename.replaceAll('\\', '/'));
    bool has(String pattern) => RegExp(
      '(?:^|[^a-z0-9])(?:$pattern)(?=\$|[^a-z0-9])',
      caseSensitive: false,
    ).hasMatch(name);
    List<String> matches(Map<String, String> patterns) => [
      for (final entry in patterns.entries)
        if (has(entry.value)) entry.key,
    ];
    final resolution = RegExp(
      r'(?:^|[^a-z0-9])((?:720|1080|1440|2160|4320)[pi])(?=$|[^a-z0-9])',
      caseSensitive: false,
    ).firstMatch(name)?.group(1)?.toLowerCase();
    final depth = RegExp(
      r'(?:^|[^a-z0-9])(?:ma|hi)?(8|10|12)(?:bit|[ -]bit|p)(?=$|[^a-z0-9])',
      caseSensitive: false,
    ).firstMatch(name)?.group(1);
    final release = <String>[], encoders = <String>[], subs = <String>[];
    final brackets = RegExp(
      r'\[([^\]]+)\]|【([^】]+)】',
    ).allMatches(name).toList();
    final outside = name
        .replaceAll(RegExp(r'\[[^\]]*\]|【[^】]*】'), ' ')
        .replaceAll(RegExp(r'\.[a-z0-9]{2,5}$', caseSensitive: false), '')
        .replaceAll(
          RegExp(r'\b(?:S\d+E\d+|EP?\d+|\d+)\b', caseSensitive: false),
          '',
        )
        .replaceAll(RegExp(r'[\s._-]+'), '');
    for (final block in brackets) {
      final raw = (block.group(1) ?? block.group(2)!).trim();
      if (raw.isEmpty) continue;
      final explicitSub = RegExp(
        r'字幕[组組]|字幕社|fansub',
        caseSensitive: false,
      ).hasMatch(raw);
      final explicitEncoder = RegExp(
        r'压制[组組]|壓製[组組]|encode[rd]?\s*(?:group|team)',
        caseSensitive: false,
      ).hasMatch(raw);
      final groupMarker = RegExp(
        r'studio|(?:^|[-_ ])subs?(?:$|[-_ ])|字幕|压制|壓製|[&＆]',
        caseSensitive: false,
      ).hasMatch(raw);
      final prefix = name
          .substring(0, block.start)
          .replaceAll(RegExp(r'\[[^\]]*\]|【[^】]*】'), '')
          .trim()
          .isEmpty;
      // Unknown prefix marks are retained only when an unbracketed title exists.
      // [86] [01] is not evidence that "86" is a release group.
      if (!explicitSub &&
          !explicitEncoder &&
          !groupMarker &&
          !(prefix && outside.isNotEmpty)) {
        continue;
      }
      if (_technical(raw)) continue;
      if (explicitSub) {
        if (!subs.contains(raw)) subs.add(raw);
      } else if (explicitEncoder) {
        if (!encoders.contains(raw)) encoders.add(raw);
      } else if (!release.contains(raw)) {
        release.add(raw);
      }
    }
    return MediaVersion._(
      releaseTags: release,
      encoderTags: encoders,
      subtitleGroups: subs,
      resolution:
          resolution ??
          (has('8k')
              ? '4320p'
              : has('4k')
              ? '2160p'
              : null),
      videoCodecs: matches({
        'HEVC / x265': r'x265|h[ .]?265|hevc',
        'AVC / x264': r'x264|h[ .]?264|avc',
        'AV1': 'av1',
      }),
      bitDepth: depth == null ? null : '$depth-bit',
      hdrFormats: matches({
        'HDR10+': r'hdr10\+',
        'HDR10': r'hdr10(?!\+)',
        'HDR': r'hdr(?!10)',
        'Dolby Vision': r'dolby[ ._-]?vision|dovi|dv',
        'SDR': 'sdr',
      }),
      audioCodecs: matches({
        'FLAC': 'flac',
        'AAC': 'aac',
        'Opus': 'opus',
        'DTS-HD MA': r'dts[ ._-]?hd[ ._-]?ma',
        'DTS': r'dts(?![ ._-]?hd)',
        'TrueHD': 'truehd',
        'E-AC-3': r'e[ ._-]?ac[ ._-]?3|ddp',
        'AC-3': r'(?<!e[- ._])ac[ ._-]?3',
        'PCM': r'pcm|lpcm',
      }),
      subtitleHints: matches({
        '简体字幕标记': r'chs|sc|gb',
        '繁體字幕標記': r'cht|tc|big5',
        '中日字幕标记': r'jpchs|jpcht|jpsc|jptc',
        'ASS 标记': r'ass|ssa',
        'PGS 标记': 'pgs',
      }),
    );
  }

  static bool _technical(String value) => RegExp(
    r'^(?:\d+|[a-f0-9]{8}|(?:ma|hi)?\d+p|\d+bit|x26[45]|h26[45]|hevc|avc|av1|flac|aac|opus|chs|cht|jptc|jpchs|jpcht|bdrip|bluray|web[ -]?dl|hdr10?\+?|sdr)(?:[ _+&-]*(?:\d+p|\d+bit|x26[45]|h26[45]|hevc|flac|aac|chs|cht))*$',
    caseSensitive: false,
  ).hasMatch(value);

  List<String> get technicalLabels => [
    ?resolution,
    ...videoCodecs,
    ?bitDepth,
    ...hdrFormats,
    ...audioCodecs,
    ...subtitleHints,
  ];

  static String? fileSize(Object? bytes) {
    if (bytes is! num || bytes < 0) return null;
    var value = bytes.toDouble();
    const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(unit == 0 ? 0 : 2)} ${units[unit]}';
  }
}
