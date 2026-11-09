import 'dart:io';

import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/image_store.dart';
import 'package:ccplayer/core/library_backup_exporter.dart';
import 'package:ccplayer/core/library_backup_restorer.dart';
import 'package:ccplayer/l10n/app_localizations.dart';
import 'package:ccplayer/ui/settings_page.dart';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final class _SelectedFile extends PlatformFile {
  _SelectedFile(this.file);
  final File file;
  @override
  Uri get uri => file.uri;
  @override
  String get name => 'backup.zip';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Picker extends FilePickerPlatform {
  _Picker(this.file);
  final File file;
  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async => _SelectedFile(file);
}

/// Shared by desktop widget tests and the Android device integration test.
/// Uses only a temporary catalog, preserving any application's real preferences.
void registerBackupRestoreFlow() {
  testWidgets(
    'preview cancel, confirm restore, and restore the automatic backup',
    (tester) async {
      late Directory temp, artwork;
      late File archive;
      late SharedPreferences prefs;
      late Map<String, Object?> oldPreferences;
      const image = [7, 8, 9];
      final imageName = 'crop_${sha256.convert(image)}.png';
      final catalog = Catalog.instance;
      final oldRoot = ImageStore.root;
      final oldPicker = FilePickerPlatform.instance;
      await tester.runAsync(() async {
        prefs = await SharedPreferences.getInstance();
        oldPreferences = {
          for (final key in LibraryBackupExporter.preferenceKeys)
            key: prefs.get(key),
        };
        temp = await Directory.systemTemp.createTemp('konata-restore-ui-');
        artwork = await Directory('${temp.path}/artwork').create();
        ImageStore.root = artwork;
        await catalog.initialize(dataDirectory: temp);
        await catalog.db.insert('sources', {
          'id': 's',
          'kind': 'local',
          'label': 'Fixture',
          'location': '${temp.path}/media',
        });
        await catalog.db.insert('works', {
          'id': 'w',
          'title': 'Backup title',
          'manual_cover_url': 'artwork:$imageName',
        });
        await catalog.db.insert('assets', {
          'id': 'a',
          'source_id': 's',
          'work_id': 'w',
          'relative_path': '01.mkv',
          'name': '01.mkv',
          'category': 'main',
        });
        await catalog.db.insert('progress', {
          'asset_id': 'a',
          'position_ms': 3210,
          'duration_ms': 9000,
          'completed': 0,
          'updated_at': '2026-11-08T00:00:00Z',
        });
        await File('${artwork.path}/$imageName').writeAsBytes(image);
        await prefs.setString('theme_mode', 'dark');
        await prefs.setInt('watched_completion_percent', 85);
        archive = File('${temp.path}/backup.zip');
        await LibraryBackupExporter(
          database: catalog.db,
          artworkDirectory: artwork,
          preferences: prefs,
        ).export(archive);
        await catalog.db.update('works', {
          'title': 'Current title',
          'manual_cover_url': null,
        });
        await File('${artwork.path}/$imageName').delete();
        await prefs.setString('theme_mode', 'light');
        await catalog.reload();
        FilePickerPlatform.instance = _Picker(archive);
      });
      Future<void> waitFor(Finder finder) async {
        for (var i = 0; i < 250 && finder.evaluate().isEmpty; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)),
          );
          await tester.pump(const Duration(milliseconds: 30));
        }
        expect(finder, findsWidgets);
        await tester.pump(const Duration(milliseconds: 350));
      }

      Future<void> waitReady() async {
        for (var i = 0; i < 250; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)),
          );
          await tester.pump(const Duration(milliseconds: 30));
          if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
        }
        await tester.pumpAndSettle();
      }

      final elapsed = Stopwatch()..start();
      try {
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(
              body: SettingsPage(category: 3, wideLayout: true),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final restore = find.byKey(const ValueKey('library-backup-inspect'));
        await tester.scrollUntilVisible(
          restore,
          160,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.tap(restore);
        final confirm = find.byKey(const ValueKey('library-backup-confirm'));
        await waitFor(confirm);
        expect(
          find.textContaining('This replaces your current library'),
          findsOneWidget,
        );
        await tester.tap(find.text('Cancel'));
        await waitReady();
        await tester.runAsync(() async {
          expect(
            (await catalog.db.query('works')).single['title'],
            'Current title',
          );
          expect(prefs.getString('theme_mode'), 'light');
        });
        await tester.tap(restore);
        await waitFor(confirm);
        await tester.tap(confirm);
        await waitFor(find.textContaining('Restore complete.'));
        await waitReady();
        await tester.runAsync(() async {
          expect(
            (await catalog.db.query('works')).single['title'],
            'Backup title',
          );
          expect(
            (await catalog.db.query('progress')).single['position_ms'],
            3210,
          );
          expect(await File('${artwork.path}/$imageName').readAsBytes(), image);
          expect(prefs.getString('theme_mode'), 'dark');
        });
        final previous = find.byKey(const ValueKey('library-backup-previous'));
        await tester.scrollUntilVisible(
          previous,
          160,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.tap(previous);
        await waitFor(find.byType(SimpleDialogOption));
        await tester.tap(find.byType(SimpleDialogOption).first);
        await waitFor(confirm);
        await tester.tap(confirm);
        // Wait for the second operation rather than the previous snackbar.
        await tester.runAsync(() async {
          for (var i = 0; i < 250; i++) {
            final rows = await catalog.db.query('works');
            if (rows.single['title'] == 'Current title' && !catalog.scanning) {
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 30));
          }
        });
        await waitReady();
        await tester.runAsync(() async {
          expect(
            (await catalog.db.query('works')).single['title'],
            'Current title',
          );
          expect(prefs.getString('theme_mode'), 'light');
          expect(
            await LibraryBackupRestorer(
              database: catalog.db,
              artworkDirectory: artwork,
            ).recoveryBackups(),
            hasLength(2),
          );
        });
        expect(catalog.scanning, isFalse);
        expect(tester.takeException(), isNull);
        debugPrint(
          'BACKUP_RESTORE_UI_PASS ${elapsed.elapsedMilliseconds}ms ${Platform.operatingSystem}',
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          for (final entry in oldPreferences.entries) {
            final value = entry.value;
            if (value == null) {
              await prefs.remove(entry.key);
            } else if (value is int) {
              await prefs.setInt(entry.key, value);
            } else {
              await prefs.setString(entry.key, value as String);
            }
          }
          await catalog.db.close();
          await temp.delete(recursive: true);
        });
        ImageStore.root = oldRoot;
        FilePickerPlatform.instance = oldPicker;
      }
    },
  );
}
