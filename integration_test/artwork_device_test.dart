// Run in the isolated .validation Android application or a test Windows runner.
import 'dart:async';
import 'dart:io';
import 'package:ccplayer/core/artwork_settings.dart';
import 'package:ccplayer/core/image_store.dart';
import 'package:ccplayer/core/optional_features.dart';
import 'package:ccplayer/core/optional_people.dart';
import 'package:ccplayer/l10n/app_localizations.dart';
import 'package:ccplayer/ui/image_cache_settings.dart';
import 'package:ccplayer/ui/nipaplay_style.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('persistent artwork and native directory entry', (tester) async {
    final bytes = (await rootBundle.load(
      'assets/brand/konata-ui.png',
    )).buffer.asUint8List();
    const url = 'https://lain.bgm.tv/artwork-device-check.png';
    final owner =
        'artwork-device-check-${DateTime.now().microsecondsSinceEpoch}';
    final root = await ImageStore.directory();
    await ImageStore.retain(owner, [url]);
    await ImageStore.storeCached(url, bytes);
    await ImageStore.close();
    expect(await ImageStore.readCached(url), bytes);
    final settings = OptionalFeatures();
    await settings.initialize();
    await settings.setEnabled(OptionalFeature.characters, true);
    final session = OptionalPeopleSession(
      settings,
      OptionalFeature.characters,
      clientFactory: () =>
          throw StateError('Cached image must not use network'),
    );
    expect(await session.image(url, Completer<void>().future), bytes);
    await settings.setEnabled(OptionalFeature.characters, false);
    expect(session.cachedImageBytes, 0);
    expect(session.activeClients, 0);
    session.dispose();
    settings.dispose();
    final used = await ImageStore.diskBytes();
    expect(used, greaterThanOrEqualTo(bytes.length));
    await ArtworkSettings.instance.load();
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        theme: NipaPlayStyle.theme(Brightness.light),
        home: const Scaffold(
          body: SafeArea(
            child: SingleChildScrollView(child: ImageCacheSettings()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await ArtworkSettings.instance.setBackdrop(false);
    await ArtworkSettings.instance.load();
    expect(ArtworkSettings.instance.backdrop, false);
    await ArtworkSettings.instance.setBackdrop(true);
    await tester.pumpAndSettle();
    if (Platform.isAndroid) {
      await const MethodChannel(
        'ccplayer/artwork',
      ).invokeMethod<void>('openDirectory');
      // Leave a short opportunity to inspect the system directory surface.
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    binding.reportData = {
      'artwork': {
        'root': root.path,
        'bytes': used,
        'offlineRead': true,
        'disabledResourcesReleased': true,
        'backdropPreference': true,
        'directoryIntentLaunched': Platform.isAndroid,
      },
    };
    expect(tester.takeException(), isNull);
    await ImageStore.close();
  });
}
