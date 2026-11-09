// Opt-in network acceptance, excluded from ordinary offline test runs.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
// Test-only injection of the interface already supplied by path_provider.
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:path_provider_windows/path_provider_windows.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../tool/cache_acceptance_probe.dart';

class _ProbePaths extends PathProviderWindows {
  _ProbePaths(this.executablePath);
  @override
  final String executablePath;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  test(
    'live cache and scraping acceptance without a desktop window',
    () async {
      final root = Directory(
        'release/validation/network-2005/windows-headless',
      ).absolute;
      // Existing empty userdata suppresses legacy migration in this isolated run.
      await Directory(p.join(root.path, 'userdata')).create(recursive: true);
      PathProviderPlatform.instance = _ProbePaths(
        p.join(root.path, 'probe.exe'),
      );
      SharedPreferences.setMockInitialValues({});
      final report = await runCacheAcceptance();
      await File(
        p.join(root.path, 'result.json'),
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
      expect(
        report['defaultArtwork'],
        p.join(root.path, 'userdata', 'artwork'),
      );
      expect(report['diskBytes'] as int, greaterThan(0));
      final samples = (report['samples'] as List).cast<Map>();
      expect(samples.where((s) => s['error'] != null), isEmpty);
      for (final sample in samples.where((s) => s['kind'] == 'characters')) {
        expect(sample['cards'] as int, greaterThan(0));
        expect(sample['images'] as List, hasLength(4));
        expect(
          (sample['images'] as List).every((i) => (i as Map)['bytes'] != null),
          true,
        );
      }
      for (final sample in samples.where((s) => s['kind'] == 'offlineImages')) {
        expect(sample['count'], 4);
      }
      expect(
        samples.singleWhere((s) => s['kind'] == 'classification')['correct'],
        true,
      );
      expect(
        samples
            .where((s) => s['kind'] == 'scrape')
            .every((s) => s['matched'] == true),
        true,
      );
    },
    timeout: const Timeout(Duration(minutes: 6)),
    skip: !const bool.fromEnvironment('CACHE_ACCEPTANCE_LIVE'),
  );
}
