// Opt-in replay of a local, private filename inventory. No network or video IO.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccplayer/core/auto_classifier.dart';
import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/personal_scraper.dart';

void main() {
  const input = String.fromEnvironment('CLOUD_INVENTORY');
  test(
    'replay real cloud inventory without touching cloud files',
    () async {
      final watch = Stopwatch()..start();
      final rows = jsonDecode(await File(input).readAsString()) as List;
      final groups = <String, Map<String, Object?>>{};
      var excluded = 0, unresolved = 0, main = 0, extras = 0;
      for (final row in rows.cast<Map>()) {
        final path = '${row['path']}/${row['name']}'.replaceFirst(
          RegExp(r'^/+'),
          '',
        );
        if (path
            .split('/')
            .any(
              (s) =>
                  RegExp(r'^(CDs?|Scans?)$', caseSensitive: false).hasMatch(s),
            )) {
          excluded++;
          continue;
        }
        final decision = AutoClassifier.decide(
          selectedRoot: row['root'].toString(),
          relativePath: path,
          rootHasDirectVideo: false,
          localRootName: '',
        );
        if (decision == null) {
          unresolved++;
          continue;
        }
        final group = groups.putIfAbsent(
          decision.folder,
          () => {
            'folder': decision.folder,
            'tmdbId': Catalog.tmdbId(decision.folder),
            'tmdbType': Catalog.tmdbType(decision.folder),
            'year': Catalog.year(decision.folder),
            'files': 0,
            'main': 0,
            'extra': 0,
            'keywords': <String, int>{},
            'sampleFiles': <String>[],
          },
        );
        group['files'] = (group['files'] as int) + 1;
        final extra = Catalog.isExtra(path);
        group[extra ? 'extra' : 'main'] =
            (group[extra ? 'extra' : 'main'] as int) + 1;
        if (extra) {
          extras++;
        } else {
          main++;
          final title =
              PersonalMetadataScraper.filenameWork(
                row['name'].toString(),
              )?['title']?.toString() ??
              '(episode only)';
          (group['keywords'] as Map<String, int>).update(
            title,
            (n) => n + 1,
            ifAbsent: () => 1,
          );
          final samples = group['sampleFiles'] as List<String>;
          if (samples.length < 4) samples.add(row['name'].toString());
        }
      }
      final summary = {
        'inventoryEntries': rows.length,
        'workGroups': groups.length,
        'mainFiles': main,
        'extraFiles': extras,
        'excludedResourceFiles': excluded,
        'ungrouped': unresolved,
        'withTmdbId': groups.values.where((g) => g['tmdbId'] != null).length,
        'withYear': groups.values.where((g) => g['year'] != null).length,
        'multipleFilenameKeywords': groups.values
            .where((g) => (g['keywords'] as Map).length > 1)
            .length,
        'elapsedMs': watch.elapsedMilliseconds,
      };
      final output = File(
        'release/validation/network-2005/cloud-inventory-replay.json',
      );
      await output.parent.create(recursive: true);
      await output.writeAsString(
        const JsonEncoder.withIndent(
          '  ',
        ).convert({'summary': summary, 'groups': groups.values.toList()}),
      );
      // ignore: avoid_print
      print('REAL_INVENTORY ${jsonEncode(summary)}');
      expect(main + extras + excluded + unresolved, rows.length);
      expect(groups.length, greaterThan(1000));
    },
    skip: input.isEmpty,
  );
}
