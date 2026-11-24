import 'dart:async';

import 'package:feature_lyrics/feature_lyrics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

import 'support/lyrics_test_helpers.dart';

void main() {
  group('ImmersiveLyricControlSheet 多端视口零溢出与换源校准闭环', () {
    testWidgets('全五组跨端标准视口下零溢出、满足触控尺寸且支持点击外部关闭', (
      tester,
    ) async {
      final bundle = KonataDatabaseBundle.openInMemory();
      addTearDown(bundle.close);
      final prefsStore = LyricsPreferencesStore(ScopedPrefsStore(bundle.userState));
      final resolver = LyricsResolver(
        cacheRepository: StorageLyricCacheRepository.fromBundle(bundle),
        raceEngine: const LyricRaceEngine(
          firstPaintGrace: Duration(milliseconds: 20),
          lowConfidencePaintAfter: Duration(milliseconds: 60),
          deadline: Duration(milliseconds: 200),
        ),
        sourcesFactory: () async => [
          FakeLyricCandidateSource(
            label: 'Netease',
            streamBuilder: (_) => Stream.fromIterable([
              const LyricCandidate(
                source: LyricSource.netease,
                sourceId: 'ncm-10',
                title: '青春コンプレックス',
                artist: '結束バンド',
                durationSeconds: 203.0,
                lrcContent: kSampleBilingualLrc,
                hasTranslation: true,
                hasRomaji: true,
              ),
            ]),
          ),
        ],
      );
      final controller = LyricDisplayController(
        resolver: resolver,
        preferencesStore: prefsStore,
      );
      addTearDown(controller.dispose);

      await controller.resolveForTrack(
        const LyricTrackQuery(
          trackKey: 'ui-vp-track',
          albumKey: 'ui-vp-album',
          title: '青春コンプレックス',
          artist: '結束バンド',
          album: '結束バンド',
          durationSeconds: 203.0,
        ),
      );
      await tester.pump(const Duration(milliseconds: 60));

      final configs = <({Size size, TargetPlatform platform})>[
        (size: const Size(1280, 800), platform: TargetPlatform.windows),
        (size: const Size(1180, 760), platform: TargetPlatform.android),
        (size: const Size(800, 1100), platform: TargetPlatform.android),
        (size: const Size(390, 844), platform: TargetPlatform.android),
        (size: const Size(844, 390), platform: TargetPlatform.android),
      ];

      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      var closeCount = 0;
      for (final cfg in configs) {
        debugDefaultTargetPlatformOverride = cfg.platform;
        tester.view.physicalSize = cfg.size;
        tester.view.devicePixelRatio = 1.0;

        await tester.pumpWidget(
          wrapLyricsTestApp(
            child: ImmersiveLyricControlSheet(
              key: ValueKey('sheet_${cfg.size.width}_${cfg.size.height}'),
              controller: controller,
              onClose: () => closeCount++,
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(tester.takeException(), isNull);
        final firstCandidate = find.byKey(
          const ValueKey('lyric_candidate_item_0'),
        );
        await tester.scrollUntilVisible(
          firstCandidate,
          120.0,
          scrollable: find.byType(Scrollable).first,
        );
        expect(tester.takeException(), isNull);
        expect(firstCandidate, findsOneWidget);

        if (cfg.platform == TargetPlatform.android) {
          final tileSize = tester.getSize(firstCandidate);
          expect(tileSize.height, greaterThanOrEqualTo(48.0));
        }
      }

      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      tester.view.physicalSize = const Size(1280, 800);
      await tester.pumpAndSettle();

      await tester.tapAt(const Offset(40, 400));
      await tester.pumpAndSettle();
      expect(closeCount, 1);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });

    testWidgets('手搜重搜 -> 切换候选锁定 -> 恢复自动 -> 三级偏移升格整专与蓝牙校准完整闭环', (
      tester,
    ) async {
      final bundle = KonataDatabaseBundle.openInMemory();
      addTearDown(bundle.close);
      final prefsStore = LyricsPreferencesStore(ScopedPrefsStore(bundle.userState));
      final resolver = LyricsResolver(
        cacheRepository: StorageLyricCacheRepository.fromBundle(bundle),
        raceEngine: const LyricRaceEngine(
          firstPaintGrace: Duration(milliseconds: 20),
          lowConfidencePaintAfter: Duration(milliseconds: 60),
          deadline: Duration(milliseconds: 250),
        ),
        sourcesFactory: () async => [
          FakeLyricCandidateSource(
            label: 'Catalog',
            streamBuilder: (q) => Stream.fromIterable([
              LyricCandidate(
                source: LyricSource.lrclib,
                sourceId: 'auto-1',
                title: q.title,
                artist: 'Singer',
                durationSeconds: 200.0,
                lrcContent: kSampleJapaneseLrc,
              ),
              LyricCandidate(
                source: LyricSource.amll,
                sourceId: 'better-amll-2',
                title: '${q.title} (逐字版)',
                artist: 'Singer',
                durationSeconds: 200.0,
                lrcContent: kSampleBilingualLrc,
                hasTranslation: true,
                hasWordTiming: true,
                hasRomaji: true,
              ),
            ]),
          ),
        ],
      );
      final controller = LyricDisplayController(
        resolver: resolver,
        preferencesStore: prefsStore,
      );
      addTearDown(controller.dispose);
      controller.updateAudioRoute(deviceName: 'Sony WH-1000XM5');

      await controller.resolveForTrack(
        const LyricTrackQuery(
          trackKey: 'e2e-track',
          albumKey: 'e2e-album',
          title: '星空のメロディ',
          artist: 'Singer',
          album: 'Star Album',
          durationSeconds: 200.0,
        ),
      );

      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        wrapLyricsTestApp(
          child: ImmersiveLyricControlSheet(
            controller: controller,
            onClose: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 1. 手动输入关键词点击搜索并切换至第二条候选（非当前生效候选），验证写入手动锁定。
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('lyric_manual_title_field')),
          matching: find.byType(EditableText),
        ),
        '星空のメロディ',
      );
      await tester.tap(find.byKey(const ValueKey('lyric_manual_search_button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('lyric_candidate_item_0')), findsOneWidget);
      expect(find.byKey(const ValueKey('lyric_candidate_item_1')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('lyric_candidate_item_1')));
      await tester.pumpAndSettle();

      expect(controller.state.isUserEdited, isTrue);
      expect(find.byKey(const ValueKey('lyric_unlock_auto_button')), findsOneWidget);

      // 2. 点击「恢复自动」解除手动锁定。
      await tester.tap(find.byKey(const ValueKey('lyric_unlock_auto_button')));
      await tester.pumpAndSettle();
      expect(controller.state.isUserEdited, isFalse);

      // 3. 切换至「三级时间轴校准」分栏：调节单曲 +0.5s -> 一键应用到整张专辑 -> 蓝牙全局延迟 +0.1s。
      await tester.tap(find.text('三级时间轴校准'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('lyric_track_offset_plus_500')));
      await tester.pumpAndSettle();
      expect(controller.state.offsetSnapshot.trackOffsetMillis, 500);
      expect(find.byKey(const ValueKey('lyric_apply_to_album_button')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('lyric_apply_to_album_button')));
      await tester.pumpAndSettle();
      expect(controller.state.offsetSnapshot.trackOffsetMillis, 0);
      expect(controller.state.offsetSnapshot.albumOffsetMillis, 500);

      final btPlus100 = find.byKey(
        const ValueKey('lyric_route_bluetooth_plus_100'),
      );
      await tester.drag(find.byType(ListView), const Offset(0, -320));
      await tester.pumpAndSettle();
      await tester.ensureVisible(btPlus100);
      await tester.pumpAndSettle();
      await tester.tap(btPlus100);
      await tester.pumpAndSettle();
      expect(controller.state.offsetSnapshot.routeOffsetMillis, 100);
      expect(controller.state.offsetSnapshot.totalOffsetMillis, 600);
      expect(find.text('+0.5s'), findsWidgets);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });

    testWidgets('embedded 内嵌暗色菜单支持双语开关、-0.2s/归零/+0.2s 微调及词源候选切换', (
      tester,
    ) async {
      final bundle = KonataDatabaseBundle.openInMemory();
      addTearDown(bundle.close);
      final prefsStore = LyricsPreferencesStore(ScopedPrefsStore(bundle.userState));
      final resolver = LyricsResolver(
        cacheRepository: StorageLyricCacheRepository.fromBundle(bundle),
        raceEngine: const LyricRaceEngine(
          firstPaintGrace: Duration(milliseconds: 20),
          lowConfidencePaintAfter: Duration(milliseconds: 60),
          deadline: Duration(milliseconds: 250),
        ),
        sourcesFactory: () async => [
          FakeLyricCandidateSource(
            label: 'Catalog',
            streamBuilder: (q) => Stream.fromIterable([
              LyricCandidate(
                source: LyricSource.netease,
                sourceId: 'ne-1',
                title: q.title,
                artist: 'Singer',
                durationSeconds: 180.0,
                lrcContent: kSampleBilingualLrc,
                hasTranslation: true,
              ),
              LyricCandidate(
                source: LyricSource.qq,
                sourceId: 'qq-2',
                title: '${q.title} (备选源)',
                artist: 'Singer',
                durationSeconds: 180.0,
                lrcContent: kSampleJapaneseLrc,
              ),
            ]),
          ),
        ],
      );
      final controller = LyricDisplayController(
        resolver: resolver,
        preferencesStore: prefsStore,
      );
      addTearDown(controller.dispose);

      await controller.resolveForTrack(
        const LyricTrackQuery(
          trackKey: 'embedded-track',
          albumKey: 'embedded-album',
          title: 'Menu Lyric Test',
          artist: 'Singer',
          durationSeconds: 180.0,
        ),
      );

      tester.view.physicalSize = const Size(420, 820);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        wrapLyricsTestApp(
          dark: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: ImmersiveLyricControlSheet(
              controller: controller,
              onClose: () {},
              embedded: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // 双语开关在浅色外部主题下也可正常交互切换并持久化。
      expect(prefsStore.read().showTranslation, isTrue);
      await tester.tap(
        find.byKey(const ValueKey('lyric_control_translation_switch')),
      );
      await tester.pumpAndSettle();
      expect(prefsStore.read().showTranslation, isFalse);

      // -0.2s / +0.2s / 归零快速偏移控制。
      await tester.tap(
        find.byKey(const ValueKey('lyric_quick_offset_minus_200')),
      );
      await tester.pumpAndSettle();
      expect(controller.state.offsetSnapshot.trackOffsetMillis, -200);

      await tester.tap(
        find.byKey(const ValueKey('lyric_quick_offset_plus_200')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('lyric_quick_offset_plus_200')),
      );
      await tester.pumpAndSettle();
      expect(controller.state.offsetSnapshot.trackOffsetMillis, 200);

      await tester.tap(find.byKey(const ValueKey('lyric_quick_offset_reset')));
      await tester.pumpAndSettle();
      expect(controller.state.offsetSnapshot.trackOffsetMillis, 0);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  });

  group('SettingsLyricsCard 来源开关与非官方免责弹窗流转', () {
    testWidgets('QQ 源默认关闭，取消免责弹窗不开启；确认一次后持久记住不再重复弹窗', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final bundle = KonataDatabaseBundle.openInMemory();
      addTearDown(bundle.close);
      final prefsStore = LyricsPreferencesStore(ScopedPrefsStore(bundle.userState));

      await tester.pumpWidget(
        wrapLyricsTestApp(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: SettingsLyricsCard(preferencesStore: prefsStore),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(prefsStore.read().qqEnabled, isFalse);
      expect(prefsStore.read().showRomaji, isFalse);

      // 1. 开启罗马音开关立即持久化生效。
      final romajiSwitch = find.byKey(
        const ValueKey('settings_lyric_show_romaji_switch'),
      );
      await tester.ensureVisible(romajiSwitch);
      await tester.tap(romajiSwitch);
      await tester.pumpAndSettle();
      expect(prefsStore.read().showRomaji, isTrue);

      // 2. 首次开启 QQ 音乐歌词源 -> 弹出非官方免责声明弹窗，点「暂不开启」保持关闭。
      final qqSwitch = find.byKey(
        const ValueKey('settings_lyric_source_qq_switch'),
      );
      await tester.ensureVisible(qqSwitch);
      await tester.tap(qqSwitch);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('qq_lyric_disclaimer_glass_dialog')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey('qq_lyric_disclaimer_cancel')),
      );
      await tester.pumpAndSettle();
      expect(prefsStore.read().qqEnabled, isFalse);
      expect(prefsStore.read().qqDisclaimerAccepted, isFalse);

      // 3. 再次尝试开启并点击「了解并开启」-> 永久记住免责确认且开启 QQ 源。
      await tester.ensureVisible(qqSwitch);
      await tester.tap(qqSwitch);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('qq_lyric_disclaimer_confirm')),
      );
      await tester.pumpAndSettle();
      expect(prefsStore.read().qqEnabled, isTrue);
      expect(prefsStore.read().qqDisclaimerAccepted, isTrue);

      // 4. 关闭后再次开启不再弹出免责声明弹窗。
      await tester.ensureVisible(qqSwitch);
      await tester.tap(qqSwitch);
      await tester.pumpAndSettle();
      expect(prefsStore.read().qqEnabled, isFalse);

      await tester.ensureVisible(qqSwitch);
      await tester.tap(qqSwitch);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('qq_lyric_disclaimer_glass_dialog')),
        findsNothing,
      );
      expect(prefsStore.read().qqEnabled, isTrue);
    });
  });
}
