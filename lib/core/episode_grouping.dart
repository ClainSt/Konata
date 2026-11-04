/// A logical episode may have several physical files / encodes.
/// Group cards without rewriting real file paths or the playback history.
class EpisodeGroup {
  const EpisodeGroup(this.key, this.versions);
  final String key;
  final List<Map<String, Object?>> versions;
  Map<String, Object?> preferred(Map<String, Map<String, Object?>> progress) {
    final list = [...versions];
    list.sort((a, b) {
      final x = progress[a['id']?.toString()];
      final y = progress[b['id']?.toString()];
      final aPos = x?['position_ms'] as int? ?? 0;
      final bPos = y?['position_ms'] as int? ?? 0;
      final aTime = x?['updated_at']?.toString() ?? '';
      final bTime = y?['updated_at']?.toString() ?? '';
      if (aPos > 0 && bPos <= 0) return -1;
      if (bPos > 0 && aPos <= 0) return 1;
      if (aPos > 0 && bPos > 0 && aTime != bTime) return bTime.compareTo(aTime);
      final aSize = a['size'] as int? ?? 0, bSize = b['size'] as int? ?? 0;
      if (aSize != bSize) return bSize.compareTo(aSize);
      return (a['relative_path']?.toString() ?? '').compareTo(
        b['relative_path']?.toString() ?? '',
      );
    });
    return list.first;
  }
}

abstract final class EpisodeGrouping {
  static List<EpisodeGroup> main(List<Map<String, Object?>> assets) {
    final grouped = <String, List<Map<String, Object?>>>{};
    for (final asset in assets.where((a) => a['category'] == 'main')) {
      final ep = asset['episode'] as int?;
      final season = asset['season'] as int? ?? 1;
      // Unnumbered videos cannot safely be merged.
      final key = ep != null && ep > 0
          ? '${asset['source_id']}|${asset['work_id']}|S$season|E$ep'
          : 'file:${asset['id'] ?? asset['relative_path']}';
      grouped.putIfAbsent(key, () => []).add(asset);
    }
    final groups = grouped.entries
        .map((e) => EpisodeGroup(e.key, e.value))
        .toList();
    groups.sort((a, b) {
      final x = a.versions.first, y = b.versions.first;
      final sx = x['season'] as int? ?? 1, sy = y['season'] as int? ?? 1;
      if (sx != sy) return sx.compareTo(sy);
      final ex = x['episode'] as int?, ey = y['episode'] as int?;
      if (ex != null && ey != null) return ex.compareTo(ey);
      if (ex != null) return -1;
      if (ey != null) return 1;
      return (x['name']?.toString() ?? '').compareTo(
        y['name']?.toString() ?? '',
      );
    });
    return groups;
  }
}
