import 'dart:io';
import 'package:ccplayer/core/bangumi_offline_index.dart';
import 'package:ccplayer/l10n/app_localizations.dart';
import 'package:ccplayer/ui/bangumi_offline_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Index extends BangumiOfflineIndex {
  _Index() : super(Directory('unused'));
  bool installed = false;
  int checked = 0;
  @override
  Future<Map<String, Object?>?> status() async => installed
      ? {
          'version': 'dump-2026-11-03.210402Z.zip',
          'subjects': '31297',
          'bytes': 10686464,
          'archive_sha256': 'a' * 64,
        }
      : null;
  @override
  Future<OfflineSnapshot> checkLatest() async {
    checked++;
    return (
      url: Uri.parse(
        'https://github.com/bangumi/Archive/releases/download/archive/test.zip',
      ),
      bytes: 450262892,
      digest: 'a' * 64,
      version: 'dump-2026-11-03.210402Z.zip',
    );
  }

  @override
  Future<void> install({
    File? zip,
    OfflineSnapshot? snapshot,
    void Function(String, int, int)? progress,
  }) async {
    installed = true;
    progress?.call('complete', 31297, 31297);
  }

  @override
  Future<void> remove() async {
    installed = false;
  }
}

void main() {
  test(
    'import removes only its own Android picker cache, preserving originals and other picks',
    () async {
      final root = await Directory.systemTemp.createTemp('offline-picker-');
      addTearDown(() => root.delete(recursive: true));
      final selected = File('${root.path}/file_picker/123/archive.zip');
      final other = File('${root.path}/file_picker/124/other.zip');
      final original = File('${root.path}/original.zip');
      for (final file in [selected, other, original]) {
        await file.parent.create(recursive: true);
        await file.writeAsBytes([1, 2, 3]);
      }
      await cleanOfflinePickerCopy(selected, root);
      await cleanOfflinePickerCopy(original, root);
      expect(await selected.exists(), false);
      expect(await selected.parent.exists(), false);
      expect(await other.exists(), true);
      expect(await original.exists(), true);
    },
  );
  for (final locale in [const Locale('zh'), const Locale('en')]) {
    testWidgets('offline updates stay user initiated and adaptive: $locale', (
      tester,
    ) async {
      final index = _Index();
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.binding.setSurfaceSize(const Size(390, 840));
      await tester.pumpWidget(
        MaterialApp(
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(1.5)),
            child: child!,
          ),
          home: BangumiOfflineSettings(index: index),
        ),
      );
      await tester.pumpAndSettle();
      expect(index.checked, 0);
      final english = locale.languageCode == 'en';
      final check = find.text(english ? 'Check for updates' : '检查更新');
      await tester.ensureVisible(check);
      await tester.tap(check);
      await tester.pumpAndSettle();
      expect(index.checked, 1);
      expect(find.textContaining('429.4 MiB'), findsOneWidget);
      final download = find.text(english ? 'Download / update' : '下载／更新');
      await tester.ensureVisible(download);
      await tester.tap(download);
      await tester.pumpAndSettle();
      expect(index.installed, true);
      expect(find.textContaining('31297'), findsOneWidget);
      for (final size in [
        const Size(850, 390),
        const Size(600, 750),
        const Size(1280, 800),
        const Size(320, 720),
      ]) {
        await tester.binding.setSurfaceSize(size);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$locale $size');
      }
    });
  }
}
