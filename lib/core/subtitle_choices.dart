import 'package:media_kit/media_kit.dart';

class SubtitleChoice {
  SubtitleChoice(
    this.track, {
    required this.external,
    this.format = '',
    Set<String>? aliases,
  }) : aliases = aliases ?? {track.id};
  final SubtitleTrack track;
  final bool external;
  final String format;
  final Set<String> aliases;
}

abstract final class SubtitleChoices {
  static String format(String? codec, String? filename) {
    final path = Uri.tryParse(filename ?? '')?.path ?? filename ?? '';
    final extension = RegExp(
      r'\.(ass|ssa|srt|vtt|sub|idx|sup)$',
      caseSensitive: false,
    ).firstMatch(path)?.group(1)?.toLowerCase();
    if (extension != null) return extension;
    final raw = (codec ?? '').toLowerCase();
    return switch (raw) {
      'subrip' => 'srt',
      'webvtt' => 'vtt',
      _ => raw,
    };
  }

  static String canonical(String value) {
    final uri = Uri.tryParse(value);
    return (uri?.path ?? value)
        .replaceAll('\\', '/')
        .split('/')
        .last
        .toLowerCase();
  }

  static List<SubtitleChoice> merge(
    List<SubtitleTrack> native,
    List<SubtitleTrack> sidecars,
    Map<String, Map<String, String>> info,
  ) {
    final result = <SubtitleChoice>[];
    for (final track in native.where((t) => t.id != 'auto' && t.id != 'no')) {
      final data = info[track.id] ?? {};
      final source = data['external-filename'] ?? '';
      final external =
          track.uri || data['external'] == 'yes' || data['external'] == 'true';
      final matches = external
          ? sidecars
                .where(
                  (s) =>
                      s.id == source ||
                      (track.title?.isNotEmpty == true &&
                          canonical(s.title ?? s.id) ==
                              canonical(track.title!)),
                )
                .toList()
          : <SubtitleTrack>[];
      final choice = SubtitleChoice(
        track,
        external: external,
        format: format(
          track.codec,
          matches.isNotEmpty ? matches.first.title : source,
        ),
        aliases: {track.id, ...matches.map((s) => s.id)},
      );
      final duplicate = result
          .where((c) => c.aliases.intersection(choice.aliases).isNotEmpty)
          .firstOrNull;
      if (duplicate != null) {
        duplicate.aliases.addAll(choice.aliases);
      } else {
        result.add(choice);
      }
    }
    for (final track in sidecars) {
      if (result.any((c) => c.aliases.contains(track.id))) continue;
      result.add(
        SubtitleChoice(
          track,
          external: true,
          format: format(track.codec, track.title ?? track.id),
        ),
      );
    }
    return result;
  }
}
