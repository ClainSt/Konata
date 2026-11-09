// Explicit, read-only sampling of the private inventory and locally stored
// credential. Credentials never enter reports, logs or packaged test assets.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage_windows/flutter_secure_storage_windows.dart';
import 'package:ccplayer/core/metadata.dart';
import 'package:ccplayer/core/metadata_http.dart';
import 'package:ccplayer/core/personal_scraper.dart';
import 'package:ccplayer/core/personal_filename_parser.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'real inventory multilingual / ID-year samples through current network',
    () async {
      HttpOverrides.global = null;
      final secrets = FlutterSecureStorageWindows(
        directory: Directory(const String.fromEnvironment('KONATA_SECRETS')),
        readLegacy: (_) async => null,
      );
      await Metadata.loadCredentials(
        (key) => secrets.read(key: key, options: const {}),
      );
      expect(
        Metadata.credentials.isConfigured,
        true,
        reason: 'Local TMDB credential unavailable',
      );
      final root = Directory('release/validation/network-2005');
      await root.create(recursive: true);
      MetadataHttp.cacheDirectory = Directory(
        '${root.path}/inventory-metadata-cache',
      );
      await MetadataHttp.cacheDirectory!.create(recursive: true);
      final replay =
          jsonDecode(
                await File(
                  '${root.path}/cloud-inventory-replay.json',
                ).readAsString(),
              )
              as Map;
      final groups = (replay['groups'] as List).cast<Map>();
      final records = <Map<String, Object?>>[];
      final verifiedSubjects = <int, int>{};
      final scraper = PersonalMetadataScraper();
      try {
        for (final id in [217512, 100565, 215956, 249854, 67043]) {
          final group = groups.firstWhere((g) => g['tmdbId'] == id);
          final folder = group['folder'].toString().split('/').last;
          final plain = PersonalFilenameParser.withoutTmdbMarkers(
            folder,
          ).trim();
          for (final mode in ['id-year', 'title-year', 'filename']) {
            final work = mode == 'filename'
                ? {
                    ...PersonalMetadataScraper.filenameWork(
                      (group['sampleFiles'] as List).first.toString(),
                    )!,
                    'year': group['year'],
                  }
                : <String, Object?>{
                    'title': mode == 'id-year' ? folder : plain,
                    'year': group['year'],
                  };
            final watch = Stopwatch()..start();
            try {
              final match = await scraper.scrape(work);
              if (mode == 'id-year' &&
                  match?.tmdbId == id &&
                  match?.bangumiId != null) {
                verifiedSubjects[id] = match!.bangumiId!;
              }
              records.add({
                'expectedTmdbId': id,
                'mode': mode,
                'query': work['title'],
                'tmdbId': match?.tmdbId,
                'bangumiId': match?.bangumiId,
                'identityVerified':
                    match?.tmdbId == id ||
                    match?.tmdbId == null &&
                        match?.bangumiId != null &&
                        match?.bangumiId == verifiedSubjects[id],
                'year': match?.year,
                'title': match?.title,
                'ms': watch.elapsedMilliseconds,
              });
            } catch (error) {
              records.add({
                'expectedTmdbId': id,
                'mode': mode,
                'error': error.runtimeType.toString(),
                'ms': watch.elapsedMilliseconds,
              });
            }
            await File('${root.path}/inventory-live.json').writeAsString(
              const JsonEncoder.withIndent('  ').convert(records),
            );
            // ignore: avoid_print
            print('INVENTORY_LIVE ${jsonEncode(records.last)}');
          }
        }
      } finally {
        scraper.close();
        Metadata.token = '';
        Metadata.apiKey = '';
      }
      expect(records.where((r) => r['identityVerified'] != true), isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 12)),
    skip: !const bool.fromEnvironment('CLOUD_INVENTORY_LIVE'),
  );
}
