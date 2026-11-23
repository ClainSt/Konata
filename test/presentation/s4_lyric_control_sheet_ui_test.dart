import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart'
    show GlobalWidgetsLocalizations;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:konata/application/playback/audio_playback_notifier.dart';
import 'package:konata/application/playback/lyric_candidate_sources.dart';
import 'package:konata/application/playback/lyric_race_engine.dart';
import 'package:konata/application/playback/lyrics_resolver.dart';
import 'package:konata/application/playback/playback_preferences_provider.dart';
import 'package:konata/application/playback/unified_playback_engine.dart';
import 'package:konata/application/providers/artwork_provider.dart';
import 'package:konata/application/providers/library_providers.dart';
import 'package:konata/domain/lyrics/lyric_candidate.dart';
import 'package:konata/domain/lyrics/lyric_search_query.dart';
import 'package:konata/domain/models/media_variant.dart';
import 'package:konata/domain/models/work.dart';
import 'package:konata/domain/playback/cue_and_lrc_parser.dart';
import 'package:konata/infrastructure/database/drift_library_repository.dart';
import 'package:konata/infrastructure/database/konata_database.dart';
import 'package:konata/presentation/audio/immersive_audio_page.dart';
import 'package:konata/presentation/audio/immersive_karaoke_sweep_text.dart';
import 'package:konata/presentation/audio/immersive_lyric_line_leaf.dart';
import 'package:konata/presentation/theme/konata_theme.dart';
import 'package:konata/presentation/widgets/design_system/konata_toast.dart';

final Uint8List _s4CoverPng = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02,
  0x08, 0x02, 0x00, 0x00, 0x00, 0xFD, 0xD4, 0x9A, 0x73, 0x00, 0x00, 0x00,
  0x14, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0x80,
  0x01, 0x31, 0x20, 0x05, 0x00, 0x32, 0x10, 0x04, 0x01, 0x96, 0x6E, 0x2B,
  0x1B, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60,
  0x82,
]);

class _UiStubCandidateSource implements LyricCandidateSource {
  int searchCalls = 0;

  @override
  String get label => 'MockMulti';

  @override
  Stream<LyricCandidate> candidates(LyricSearchQuery query) async* {
    searchCalls++;
    yield const LyricCandidate(
      source: LyricSource.amll,
      sourceId: 'amll_1',
      title: '青春コンプレックス',
      artist: '結束バンド',
      durationSeconds: 204,
      hasWordTiming: true,
      hasTranslation: true,
      lrcContent:
          '[00:10.00]<00:10.000-00:10.500>光る<00:10.700-00:11.200>なら\n'
          '[00:14.00]<00:14.000-00:14.800>次の夜へ\n'
          '[00:18.00]<00:18.000-00:18.800>駆け抜けて',
    );
    yield const LyricCandidate(
      source: LyricSource.netease,
      sourceId: 'ncm_2',
      title: '青春コンプレックス (Live)',
      artist: '結束バンド',
      durationSeconds: 208,
      hasTranslation: true,
      lrcContent:
          '[00:10.00]现场版第一句\n[00:14.00]现场版第二句\n[00:18.00]现场版第三句',
    );
  }
}

class _S4SeededAudioNotifier extends AudioPlaybackNotifier {
  _S4SeededAudioNotifier(AudioPlaybackState seed) : super(initialState: seed);

  void pushState(AudioPlaybackState next) => state = next;
}

AudioPlaybackState _seedState() {
  const work = Work(id: 'w_ui_s4', title: '孤独摇滚！');
  const v1 = MediaVariant(
    id: 'v1',
    workId: 'w_ui_s4',
    sourceId: 's1',
    relativePath: 'CD/01.flac',
    fileName: '01.flac',
    fileSize: 2048,
    assetKind: AssetKind.cdAlbum,
  );
  const lrcText = '''
[00:10.00]<00:10.000-00:10.500>光る<00:10.700-00:11.200>なら
[00:14.00]<00:14.000-00:14.800>次の夜へ
[00:18.00]<00:18.000-00:18.800>駆け抜けて
''';
  return AudioPlaybackState(
    isActive: true,
    isPlaying: false,
    queue: const [
      AudioQueueItem(
        id: 'q_ui_1',
        work: work,
        variant: v1,
        title: '青春コンプレックス',
        performer: '結束バンド',
        albumTitle: '結束バンド',
        duration: Duration(seconds: 204),
      ),
    ],
    currentIndex: 0,
    positionSeconds: 10.2,
    durationSeconds: 204.0,
    lrcDocument: LrcParser.parseText(lrcText),
    activeLyricIndex: 0,
    activeLyricSource: LyricSource.amll,
    activeLyricSourceId: 'amll_1',
    cover: MemoryAudioCover(_s4CoverPng),
  );
}

Widget _wrapImmersivePage(
  _S4SeededAudioNotifier Function() factory, {
  _UiStubCandidateSource? mockSource,
}) {
  final source = mockSource ?? _UiStubCandidateSource();
  return ProviderScope(
    overrides: [
      libraryRepositoryProvider.overrideWith((ref) {
        final db = KonataDatabase(NativeDatabase.memory());
        ref.onDispose(db.close);
        return DriftLibraryRepository(db);
      }),
      libraryItemsProvider.overrideWith((ref) async => const []),
      playbackPreferencesProvider.overrideWith(
        () => PlaybackPreferencesNotifier(enablePersistence: false),
      ),
      tmdbImageLoaderProvider.overrideWithValue(
        (_, {targetWidth, imageSize}) async => _s4CoverPng,
      ),
      lyricsResolverProvider.overrideWith((ref) {
        final resolver = LyricsResolver(
          playbackEngine: ref.read(unifiedPlaybackEngineProvider),
          cacheRepository: ref.read(lyricCacheRepositoryProvider),
          isMeteredNetwork: () async => false,
          sourcesFactory: () async => [source],
          raceEngine: const LyricRaceEngine(
            firstPaintGrace: Duration(milliseconds: 10),
            lowConfidencePaintAfter: Duration(milliseconds: 20),
            deadline: Duration(milliseconds: 200),
          ),
        );
        ref.onDispose(resolver.cancelPendingLookups);
        return resolver;
      }),
      audioPlaybackProvider.overrideWith(factory),
    ],
    child: MaterialApp(
      theme: KonataTheme.darkTheme(),
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const Stack(
        children: [
          ImmersiveAudioPage(),
          KonataToastViewport(),
        ],
      ),
    ),
  );
}

void main() {
  setUpAll(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  group('S4 全端自适应歌词控制侧栏布局与热区验收', () {
    final viewports = <({
      String label,
      TargetPlatform platform,
      Size size,
      bool checkTouchTarget,
    })>[
      (
        label: 'Windows 桌面 1280x800',
        platform: TargetPlatform.windows,
        size: const Size(1280, 800),
        checkTouchTarget: false,
      ),
      (
        label: 'Android 平板横屏 1280x800',
        platform: TargetPlatform.android,
        size: const Size(1280, 800),
        checkTouchTarget: true,
      ),
      (
        label: 'Android 平板竖屏 800x1280',
        platform: TargetPlatform.android,
        size: const Size(800, 1280),
        checkTouchTarget: true,
      ),
      (
        label: 'Android 手机竖屏 390x844',
        platform: TargetPlatform.android,
        size: const Size(390, 844),
        checkTouchTarget: true,
      ),
      (
        label: 'Android 手机矮横屏 844x390',
        platform: TargetPlatform.android,
        size: const Size(844, 390),
        checkTouchTarget: true,
      ),
    ];

    for (final vp in viewports) {
      testWidgets('${vp.label}：顶栏入口可见、热区达标、双页签打开零溢出且 Escape 可关闭', (
        tester,
      ) async {
        debugDefaultTargetPlatformOverride = vp.platform;
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = vp.size;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          debugDefaultTargetPlatformOverride = null;
        });

        await tester.pumpWidget(
          _wrapImmersivePage(() => _S4SeededAudioNotifier(_seedState())),
        );
        await tester.pumpAndSettle();

        final btnFinder = find.byKey(
          const ValueKey('immersive_lyric_control_button'),
        );
        expect(btnFinder, findsOneWidget);
        if (vp.checkTouchTarget) {
          final btnSize = tester.getSize(btnFinder);
          expect(btnSize.width, greaterThanOrEqualTo(48.0));
          expect(btnSize.height, greaterThanOrEqualTo(48.0));
        }

        await tester.tap(btnFinder);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('immersive_lyric_control_sheet')),
          findsOneWidget,
        );

        // 切至「三级时间轴校准」页签并校验无布局溢出异常。
        await tester.tap(find.text('三级时间轴校准'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('lyric_total_offset_value')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);

        // 按 Escape 收起侧栏。
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('immersive_lyric_control_sheet')),
          findsNothing,
        );
      });
    }
  });

  group('S4 换候选重搜、三级偏移闭环与扫白实时偏移联动', () {
    testWidgets('真实扩展全链路：手动重搜换源锁定、恢复自动与单曲/专辑/路由偏移交互全部生效', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1280, 800);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        debugDefaultTargetPlatformOverride = null;
      });

      final mockSource = _UiStubCandidateSource();
      late _S4SeededAudioNotifier notifier;
      await tester.pumpWidget(
        _wrapImmersivePage(() {
          notifier = _S4SeededAudioNotifier(_seedState());
          return notifier;
        }, mockSource: mockSource),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey('immersive_lyric_control_button')),
      );
      await tester.pumpAndSettle();

      // 手动搜索并点击第二条候选切换锁定（全链路走真实 AudioPlaybackLyrics + Drift 持久锁）。
      await tester.tap(
        find.byKey(const ValueKey('lyric_manual_search_button')),
      );
      await tester.pumpAndSettle();
      expect(mockSource.searchCalls, 1);
      expect(find.byKey(const ValueKey('lyric_candidate_item_1')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('lyric_candidate_item_1')));
      await tester.pumpAndSettle();
      expect(notifier.state.isLyricUserEdited, isTrue);
      expect(notifier.state.activeLyricSourceId, 'ncm_2');
      expect(find.byKey(const ValueKey('lyric_unlock_auto_button')), findsOneWidget);

      // 点击恢复自动：解除锁定并重新竞速回到最高分 amll_1。
      await tester.tap(find.byKey(const ValueKey('lyric_unlock_auto_button')));
      await tester.pumpAndSettle();
      expect(notifier.state.isLyricUserEdited, isFalse);
      expect(notifier.state.activeLyricSourceId, 'amll_1');

      // 切至偏移页签：单曲 +0.5s -> 一键提升到整张专辑 -> 蓝牙路由 +0.1s。
      await tester.tap(find.text('三级时间轴校准'));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey('lyric_track_offset_plus_500')),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('lyric_total_offset_value')))
            .data,
        '+0.5s',
      );
      expect(
        find.byKey(const ValueKey('lyric_apply_to_album_button')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey('lyric_apply_to_album_button')),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('lyric_track_offset_value')))
            .data,
        '0.0s',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('lyric_album_offset_value')))
            .data,
        '+0.5s',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('lyric_total_offset_value')))
            .data,
        '+0.5s',
      );

      await tester.drag(
        find.descendant(
          of: find.byKey(const ValueKey('immersive_lyric_control_sheet')),
          matching: find.byType(ListView),
        ),
        const Offset(0, -400),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('lyric_route_bluetooth_plus_100')),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('lyric_route_bluetooth_value')),
            )
            .data,
        '+0.1s',
      );
    });

    testWidgets('ImmersiveLyricLineLeaf 实时叠加三级偏移驱动逐字扫白（零重解析）', (
      tester,
    ) async {
      const enhanced = '''
[00:10.00]<00:10.000-00:10.500>光る<00:10.700-00:11.200>なら
[00:14.00]<00:14.000-00:14.800>次の夜へ
''';
      final doc = LrcParser.parseText(enhanced);
      late _S4SeededAudioNotifier notifier;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            libraryRepositoryProvider.overrideWith((ref) {
              final db = KonataDatabase(NativeDatabase.memory());
              ref.onDispose(db.close);
              return DriftLibraryRepository(db);
            }),
            audioPlaybackProvider.overrideWith(() {
              notifier = _S4SeededAudioNotifier(
                AudioPlaybackState(
                  isActive: true,
                  isPlaying: false,
                  queue: _seedState().queue,
                  currentIndex: 0,
                  positionSeconds: 10.2,
                  durationSeconds: 180.0,
                  lrcDocument: doc,
                  activeLyricIndex: 0,
                ),
              );
              return notifier;
            }),
          ],
          child: MaterialApp(
            theme: KonataTheme.darkTheme(),
            home: Scaffold(
              body: SizedBox(
                width: 320,
                child: ImmersiveLyricLineLeaf(
                  index: 0,
                  line: doc.lines.first,
                  nextLineStartSeconds: doc.lines[1].startSeconds,
                  secondsPerMora: doc.secondsPerMora,
                  isJapaneseSong: doc.isJapaneseSong,
                  compact: false,
                  userScrolling: false,
                ),
              ),
            ),
          ),
        ),
      );

      final sweep = tester.widget<ImmersiveKaraokeSweepText>(
        find.byKey(const ValueKey('active_lead_spans')),
      );
      final beforeOffset = sweep.progress.value;
      expect(beforeOffset, lessThan(0.35));

      // 真实调用 AudioPlaybackLyrics 扩展实时叠加 +600ms 偏移：10.2 + 0.6 = 10.8s，直接跨越至后半词“なら”。
      await notifier.adjustTrackLyricOffsetMillis(600);
      await tester.pump();
      expect(sweep.progress.value, greaterThan(0.55));
    });
  });
}
