// Opt-in, isolated Android acceptance entry. Never used by lib/main.dart.
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ccplayer/core/bangumi_offline_index.dart';
import 'package:ccplayer/core/personal_scraper.dart';
import 'package:ccplayer/l10n/app_localizations.dart';
import 'package:ccplayer/ui/bangumi_offline_settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final external = (await getExternalStorageDirectory())!;
  final support = await getApplicationSupportDirectory();
  final index = BangumiOfflineIndex(Directory('${support.path}/offline-test'));
  final archive = File('${external.path}/archive.zip');
  final report = File('${external.path}/result.json');
  final phase = ValueNotifier('准备离线数据库验收');
  runApp(
    MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              ValueListenableBuilder(
                valueListenable: phase,
                builder: (_, value, _) => Text(value),
              ),
              Expanded(child: BangumiOfflineSettings(index: index)),
            ],
          ),
        ),
      ),
    ),
  );
  await File('${external.path}/ready.txt').writeAsString('ready');
  if (!await archive.exists()) {
    phase.value = '等待测试 ZIP，复制完成后重新启动';
    return;
  }
  final evidence = <String, Object?>{
    'started': DateTime.now().toUtc().toIso8601String(),
    'dataPath': index.root.path,
  };
  Future<void> save() => report.writeAsString(
    const JsonEncoder.withIndent('  ').convert(evidence),
  );
  void require(bool value, String label) {
    if (!value) throw StateError(label);
    (evidence['checks'] ??= <String>[]) as List<String>;
    (evidence['checks'] as List<String>).add(label);
  }

  Future<String> digest(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();
  try {
    final restart = File('${external.path}/restart-check');
    if (!await restart.exists()) {
      await index.remove();
      phase.value = '导入真实官方快照';
      final clock = Stopwatch()..start();
      await index.install(zip: archive);
      evidence['importMs'] = clock.elapsedMilliseconds;
      evidence['installed'] = await index.status();
      require(
        (await index.status())?['subjects'] == '31297',
        'real_archive_31297_animation_subjects',
      );
      final old = File('${index.root.path}/animation.sqlite');
      final original = await digest(old);
      final bad = File('${external.path}/invalid.zip');
      await bad.writeAsBytes([1, 2, 3]);
      var rejected = false;
      try {
        await index.install(zip: bad);
      } catch (_) {
        rejected = true;
      }
      require(
        rejected && await digest(old) == original,
        'corrupt_update_keeps_previous_database',
      );
      await bad.delete();
      phase.value = '验证更新取消和旧库读取';
      Future<List<Map<String, dynamic>>>? duringUpdate;
      var cancelled = false;
      try {
        await index.install(
          zip: archive,
          progress: (stage, done, total) {
            if (stage == 'import') duringUpdate = index.lookup('Hyouka');
            if (stage == 'index') index.cancel();
          },
        );
      } on OfflineIndexCancelled {
        cancelled = true;
      }
      require(
        cancelled && await digest(old) == original,
        'cancelled_update_keeps_previous_database',
      );
      require(
        (await duringUpdate!).isNotEmpty,
        'old_index_readable_during_update',
      );
      final generation = BangumiOfflineIndex.generation;
      phase.value = '验证完成更新';
      clock.reset();
      await index.install(zip: archive);
      evidence['updateMs'] = clock.elapsedMilliseconds;
      require(
        BangumiOfflineIndex.generation > generation,
        'completed_update_invalidates_old_lookup_cache',
      );
      require(
        (await index.status())?['subjects'] == '31297',
        'completed_update_readable',
      );
      require(
        (await index.root.list().where((e) => e is Directory).toList()).isEmpty,
        'import_scratch_cleaned',
      );
      await restart.writeAsString('restart');
    } else {
      require(
        (await index.status())?['subjects'] == '31297',
        'index_survives_process_restart',
      );
    }
    final requests = <String>[];
    final scraper = PersonalMetadataScraper(
      offlineIndex: index,
      client: MockClient((request) async {
        requests.add('${request.method} ${request.url.path}');
        if (request.method == 'GET') {
          throw const SocketException('Deliberately offline');
        }
        return http.Response('{"data":[]}', 200);
      }),
    );
    try {
      final match = await scraper.scrape({'title': 'Hyouka', 'year': 2012});
      require(match?.bangumiId == 27364, 'offline_formal_alias_and_year_match');
      require(
        requests.every((r) => !r.startsWith('POST')),
        'offline_identity_does_not_search_network',
      );
    } finally {
      scraper.close();
    }
    evidence['requests'] = requests;
    final pickerCache = Directory(
      '${(await getTemporaryDirectory()).path}/file_picker',
    );
    var pickerBytes = 0;
    if (await pickerCache.exists()) {
      await for (final item in pickerCache.list(
        recursive: true,
        followLinks: false,
      )) {
        if (item is File) pickerBytes += await item.length();
      }
    }
    evidence['pickerCacheBytes'] = pickerBytes;
    if (await File('${external.path}/network-probe').exists()) {
      try {
        evidence['systemProxy'] = await const MethodChannel(
          'ccplayer/network',
        ).invokeMethod<String>('proxy', BangumiOfflineIndex.latestUrl);
        final latest = await index.checkLatest();
        evidence['updateCheck'] = {
          'version': latest.version,
          'bytes': latest.bytes,
          'digest': latest.digest,
        };
        if (await File('${external.path}/download-probe').exists()) {
          final download = BangumiOfflineIndex(
            Directory('${support.path}/network-download-test'),
          );
          final partial = File('${download.root.path}/archive.part');
          final sizes = <int>[];
          try {
            for (var attempt = 0; attempt < 2; attempt++) {
              var cancelled = false;
              try {
                await download.install(
                  snapshot: latest,
                  progress: (phase, done, total) {
                    if (phase == 'download') download.cancel();
                  },
                );
              } on OfflineIndexCancelled {
                cancelled = true;
              }
              require(cancelled, 'network_download_cancelled_$attempt');
              sizes.add(await partial.length());
            }
            require(sizes[1] > sizes[0], 'real_https_redirect_range_resume');
            evidence['downloadPartialBytes'] = sizes;
          } finally {
            await download.remove();
          }
        }
      } catch (error) {
        evidence['updateCheckError'] = '$error';
      }
    }
    evidence['rssBytes'] = ProcessInfo.currentRss;
    evidence['maxRssBytes'] = ProcessInfo.maxRss;
    evidence['passed'] = true;
    phase.value = '离线数据库验收通过';
  } catch (error, stack) {
    evidence['passed'] = false;
    evidence['error'] = '$error';
    evidence['stack'] = '$stack';
    phase.value = '验收失败，详见导出记录';
  }
  await save();
}
