import 'dart:convert';

class BangumiLinks {
  static List<int> ids(Map<String, Object?> work) {
    final ids = <int>{
      if (work['bangumi_id'] is num) (work['bangumi_id'] as num).toInt(),
    };
    try {
      final saved = jsonDecode(work['bangumi_ids']?.toString() ?? '[]');
      if (saved is List) {
        ids.addAll(saved.whereType<num>().map((e) => e.toInt()));
      }
    } catch (_) {}
    return ids.where((e) => e > 0).toList();
  }

  static List<Map<String, dynamic>> mergeCharacters(
    List<List<Map<String, dynamic>>> groups, {
    List<int> manualOrder = const [],
  }) {
    final merged = <int, Map<String, dynamic>>{};
    for (final group in groups) {
      for (final c in group) {
        if (c['id'] is! num) continue;
        final id = (c['id'] as num).toInt();
        if (!merged.containsKey(id)) {
          merged[id] = {
            ...c,
            'actors': List.of(c['actors'] as List? ?? []),
            'sources': List.of(c['sources'] as List? ?? []),
          };
          continue;
        }
        final old = merged[id]!;
        for (final key in ['image', 'name', 'name_cn']) {
          if (old[key] == null || old[key].toString().isEmpty) {
            old[key] = c[key];
          }
        }
        if (c['relation'] == '主角') old['relation'] = '主角';
        old['actors'] = {
          <dynamic>{...old['actors'] as List, ...c['actors'] as List? ?? []},
        }.first.toList();
        final actorDetails = <Object, Map>{};
        for (final actor in [
          ...old['actorDetails'] as List? ?? [],
          ...c['actorDetails'] as List? ?? [],
        ].whereType<Map>()) {
          if (actor['id'] != null) actorDetails[actor['id']!] = actor;
        }
        old['actorDetails'] = actorDetails.values.toList();
        old['sources'] = {
          <dynamic>{...old['sources'] as List, ...c['sources'] as List? ?? []},
        }.first.toList();
      }
    }
    final stable = merged.values.toList();
    final positions = {
      for (var i = 0; i < stable.length; i++) stable[i]['id']: i,
    };
    int rank(Map c) => c['relation'] == '主角'
        ? 0
        : c['relation'] == '配角'
        ? 1
        : 2;
    stable.sort((a, b) {
      final x = manualOrder.indexOf(a['id']), y = manualOrder.indexOf(b['id']);
      if (x >= 0 || y >= 0) {
        return (x < 0 ? 999999 : x).compareTo(y < 0 ? 999999 : y);
      }
      final role = rank(a).compareTo(rank(b));
      return role != 0
          ? role
          : positions[a['id']]!.compareTo(positions[b['id']]!);
    });
    return stable;
  }
}
