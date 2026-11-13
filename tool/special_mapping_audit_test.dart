// Opt-in regression audit using locally saved independent metadata evidence.
// No network, credentials, database, or release build is used.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccplayer/core/cloud_media_asset_presentation.dart';
import 'package:ccplayer/core/episode_metadata.dart';

void main() {
  final root = 'release/validation/special-audit-20261111';
  final cases = (jsonDecode(File('$root/deeper/regression-cases.json').readAsStringSync()) as Map)['cases'] as List;
  Map<String, Object?> asset(int index) {
    final sample = (cases.singleWhere((c) => c['sample']['index'] == index) as Map)['sample'] as Map;
    return {'name': sample['name'], 'relative_path': '${sample['path']}/${sample['name']}', 'category': 'extra'};
  }
  final responses = jsonDecode(File('$root/evidence.json').readAsStringSync()) as List;
  List<Map<String, dynamic>> specials(int id) =>
      ((responses.singleWhere((r) => r['key'] == 'tmdb-$id-s0')['data']['episodes']) as List)
          .map((e) => Map<String, dynamic>.from(e as Map)).toList();

  test('unidentified Buddy SP01 must not display the recap by number alone', () {
    final rows = {for (final e in specials(60663)) '${e['episode_number']}': e};
    expect(EpisodeMetadata.lookup({}, {'specials': rows}, asset(683)), isEmpty);
  });

  test('OVA CM must not take the story OVA through ordering fallback', () {
    expect(CloudMediaAssetPresentation.mapSpecialEpisodes(
      assets: [asset(4545)],
      // Known TMDB episode, with a synthetic OVA label to exercise the
      // documented type-pool fallback independently of locale wording.
      specials: [{...specials(127549).single, 'name': 'OVA 恋に気づく前のちょっとした話。'}],
    ), isEmpty);
  });

  test('menu does not receive story metadata', () {
    expect(EpisodeMetadata.lookup({}, {'specials': {'1': {'name': 'story'}}}, asset(485)), isEmpty);
  });

  test('manual season zero choice wins over conflicting cached automatic metadata', () {
    final file = {...asset(683), 'manual_mapping': true, 'season': 0, 'episode': 3};
    final result = EpisodeMetadata.lookup({}, {
      'specialAssets': {file['relative_path']: {'name': 'wrong cached automatic selection'}},
      'specials': {'3': {'name': 'chosen by user'}},
    }, file);
    expect(result['name'], 'chosen by user');
  });
}
