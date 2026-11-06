import 'dart:io';

import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/mpv_config_store.dart';
import 'package:ccplayer/l10n/app_localizations.dart';
import 'package:ccplayer/ui/watch_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'webdav_trial_support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const sourceUrl = String.fromEnvironment('DAV_RESUME_FIXTURE_ROOT');
  testWidgets(
    'reopen a final-frame WebDAV bookmark from the beginning',
    (tester) async {
      MediaKit.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      final root = await Directory.systemTemp.createTemp('dav-resume-');
      final catalog = Catalog.instance;
      await catalog.initialize(dataDirectory: root);
      try {
        final source = await catalog.addSource('webdav', 'fixture', sourceUrl);
        const file =
            'h264-8-1080.mkv'; // Four-second, 24 fps synthetic fixture.
        final asset = {
          'id': 'clip',
          'source_id': source,
          'relative_path': file,
          'name': file,
          'work_id': 'work',
          'category': 'main',
        };
        await catalog.db.insert('works', {'id': 'work', 'title': 'fixture'});
        await catalog.db.insert('assets', asset);
        await catalog.progress('clip', 3965, 4000);
        final config = MpvConfigStore(
          rootOverride: Directory('${root.path}/mpv'),
        );
        await config.initialize();
        final key = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: WatchPage(key: key, asset: asset, configurationStore: config),
          ),
        );
        final dynamic page = key.currentState;
        final player = page.player as Player;
        final native = player.platform as NativePlayer;
        try {
          await player.setVolume(0);
          await (page.controller as VideoController).waitUntilFirstFrameRendered
              .timeout(const Duration(seconds: 20));
          await poll(tester, () async {
            final position = player.state.position.inMilliseconds;
            return position >= 350 && position < 2000 && player.state.playing;
          }, seconds: 8);
          expect(player.state.duration.inMilliseconds, 4000);
          record('webdav_resume_from_end', {
            'saved_ms': 3965,
            'duration_ms': 4000,
            'playing_ms': player.state.position.inMilliseconds,
          });
        } finally {
          await tester.pumpWidget(const SizedBox());
          await poll(tester, () async => native.disposed, seconds: 10);
        }
      } finally {
        await catalog.db.close();
        await root.delete(recursive: true);
      }
    },
    skip: sourceUrl.isEmpty,
  );
}
