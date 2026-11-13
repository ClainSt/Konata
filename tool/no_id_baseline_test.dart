// Opt-in, offline characterization. Outputs observations, not identity accuracy.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccplayer/core/auto_classifier.dart';
import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/personal_scraper.dart';
import 'package:ccplayer/core/personal_filename_parser.dart';

void main() {
  const input = String.fromEnvironment('NO_ID_CASES');
  const output = String.fromEnvironment('NO_ID_OUTPUT');
  test(
    'observe current parser and folder grouping without ID or network',
    () async {
      final cases = jsonDecode(await File(input).readAsString()) as List;
      final observations = <Map<String, Object?>>[];
      var extras = 0, ungrouped = 0, noTitle = 0;
      final watch = Stopwatch()..start();
      for (final item in cases.cast<Map>()) {
        final row = item['input'] as Map;
        final path = '${row['path']}/${row['name']}'.replaceFirst(
          RegExp(r'^/+'),
          '',
        );
        expect(PersonalFilenameParser.tmdbIds(path), isEmpty);
        final group = AutoClassifier.decide(
          selectedRoot: row['root'] as String,
          relativePath: path,
          rootHasDirectVideo: false,
          localRootName: '',
        );
        final extra = Catalog.isExtra(path);
        final parsed = PersonalMetadataScraper.filenameWork(
          row['name'] as String,
        );
        if (extra) extras++;
        if (group == null) ungrouped++;
        if (parsed == null) noTitle++;
        observations.add({
          'case_id': item['case_id'],
          'cohort': item['cohort'],
          'split': item['split'],
          'folder': group?.folder,
          'folder_review': group?.needsReview,
          'extra': extra,
          'episode': Catalog.episode(row['name'] as String),
          'filename_work': parsed,
          'folder_year': group == null ? null : Catalog.year(group.folder),
        });
      }
      final summary = {
        'records': cases.length,
        'extra': extras,
        'ungrouped': ungrouped,
        'without_filename_work': noTitle,
        'elapsed_ms': watch.elapsedMilliseconds,
        'network_requests': 0,
        'media_reads': 0,
        'scope':
            'shared parser and AutoClassifier only; not full legacy/new recognition',
        'accuracy': null,
      };
      await File(output).writeAsString(
        jsonEncode({'summary': summary, 'observations': observations}),
      );
      print('NO_ID_BASELINE ${jsonEncode(summary)}');
      expect(observations.length, cases.length);
    },
    skip: input.isEmpty || output.isEmpty,
  );
}
