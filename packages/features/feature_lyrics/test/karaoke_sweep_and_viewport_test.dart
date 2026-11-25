import 'package:engine_playback/engine_playback.dart';
import 'package:feature_lyrics/feature_lyrics.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';
import 'package:konata_storage/konata_storage.dart';

import 'support/lyrics_test_helpers.dart';

void main() {
  testWidgets('宿主推送曲内时钟时 19 秒第三行自动聚焦，前后跳转与暂停同步', (tester) async {
    final db = KonataDatabaseBundle.openInMemory();
    addTearDown(db.close);
    final controller = LyricDisplayController(
      resolver: LyricsResolver(
        cacheRepository: StorageLyricCacheRepository.fromBundle(db),
        sourcesFactory: () async => const [],
      ),
      preferencesStore: LyricsPreferencesStore(ScopedPrefsStore(db.userState)),
    );
    addTearDown(controller.dispose);
    const lrc =
        '[00:00.00]First line\n[00:08.00]Second line\n[00:16.00]Third line\n[00:24.00]Fourth line';
    await controller.resolveForTrack(
      const LyricTrackQuery(
        trackKey: 'evening',
        albumKey: 'test',
        title: 'Evening Shore',
        artist: 'Tester',
        durationSeconds: 32,
        embeddedLrcText: lrc,
      ),
    );
    await tester.pumpWidget(
      wrapLyricsTestApp(
        child: SizedBox(
          width: 500,
          height: 460,
          child: ImmersiveLyricsViewport(
            itemId: 'evening',
            controller: controller,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final scroll = tester
        .widget<Scrollable>(
          find.descendant(
            of: find.byKey(const ValueKey('immersive_lyrics_list')),
            matching: find.byType(Scrollable),
          ),
        )
        .controller!;
    final initial = scroll.offset;
    controller.updatePlaybackPosition(
      const Duration(seconds: 19),
      isPlaying: true,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump(const Duration(milliseconds: 50));
    expect(controller.state.activeLyricIndex, 2);
    expect(scroll.offset, greaterThan(initial));
    controller.updatePlaybackPosition(
      const Duration(seconds: 3),
      isPlaying: false,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump(const Duration(milliseconds: 50));
    expect(controller.state.activeLyricIndex, 0);
    expect(controller.isPlayingListenable.value, isFalse);
    controller.updatePlaybackPosition(
      const Duration(seconds: 25),
      isPlaying: true,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump(const Duration(milliseconds: 50));
    expect(controller.state.activeLyricIndex, 3);
    expect(controller.isPlayingListenable.value, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('切换到无可靠曲名的曲目清空上一曲歌词并停止逐字时钟', (tester) async {
    final db = KonataDatabaseBundle.openInMemory();
    addTearDown(db.close);
    var requests = 0;
    final controller = LyricDisplayController(
      resolver: LyricsResolver(
        cacheRepository: StorageLyricCacheRepository.fromBundle(db),
        sourcesFactory: () async {
          requests++;
          return const [];
        },
      ),
      preferencesStore: LyricsPreferencesStore(ScopedPrefsStore(db.userState)),
    );
    addTearDown(controller.dispose);
    await controller.resolveForTrack(
      const LyricTrackQuery(
        trackKey: 'named',
        albumKey: 'fixture',
        title: '有歌词曲目',
        durationSeconds: 32,
        embeddedLrcText: '[00:00.00]第一行\n[00:08.00]第二行\n[00:16.00]第三行',
      ),
    );
    await tester.pumpWidget(
      wrapLyricsTestApp(
        child: SizedBox(
          width: 500,
          height: 460,
          child: ImmersiveLyricsViewport(
            itemId: 'named',
            controller: controller,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('immersive_lyrics_list')), findsOneWidget);
    await controller.resolveForTrack(
      const LyricTrackQuery(
        trackKey: 'weak',
        albumKey: 'fixture',
        title: '01',
        durationSeconds: 45,
      ),
    );
    await tester.pumpWidget(
      wrapLyricsTestApp(
        child: SizedBox(
          width: 500,
          height: 460,
          child: ImmersiveLyricsViewport(
            itemId: 'weak',
            controller: controller,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('当前曲目暂无同步歌词'), findsOneWidget);
    expect(find.byKey(const ValueKey('immersive_lyrics_list')), findsNothing);
    expect(controller.state.lrcDocument, isNull);
    expect(controller.state.activeLyricIndex, -1);
    expect(controller.state.isLookupInFlight, isFalse);
    controller.updatePlaybackPosition(
      const Duration(seconds: 19),
      isPlaying: true,
    );
    await tester.pumpAndSettle();
    expect(SchedulerBinding.instance.transientCallbackCount, 0);
    expect(requests, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
  group('ImmersiveLyricLineLeaf 帧时钟启停与渲染隔离', () {
    testWidgets('直连播放叶子监听在暂停、不可见与行播完后立即停摆 Ticker', (tester) async {
      final pos = ValueNotifier<Duration>(const Duration(milliseconds: 10300));
      final playing = ValueNotifier<bool>(true);
      final tickerEnabled = ValueNotifier<bool>(true);
      addTearDown(pos.dispose);
      addTearDown(playing.dispose);
      addTearDown(tickerEnabled.dispose);

      const docLrc = '''
[00:10.00]<00:10.000-00:11.000>光<00:11.000-00:12.000>の海
[00:10.00]光之海
[00:10.00]roma:hikari no umi
[00:15.00]風になる
''';
      final doc = LrcParser.parseText(docLrc);
      final spanLines = LyricVersionMatcher.parseActiveSpanLines(docLrc);

      await tester.pumpWidget(
        wrapLyricsTestApp(
          child: ValueListenableBuilder<bool>(
            valueListenable: tickerEnabled,
            builder: (context, enabled, _) => TickerMode(
              enabled: enabled,
              child: SizedBox(
                width: 420,
                child: ImmersiveLyricLineLeaf(
                  index: 0,
                  line: doc.lines[0],
                  activeLyricIndex: 0,
                  positionListenable: pos,
                  isPlayingListenable: playing,
                  showRomaji: false,
                  compact: false,
                  userScrolling: false,
                  activeSpanLine: spanLines[0],
                  nextLineStartSeconds: doc.lines[1].startSeconds,
                ),
              ),
            ),
          ),
        ),
      );

      await tester.pump();
      // 播放且可见且位于行时间窗内：扫白帧时钟必须激活运行，且多行扫白组件已渲染。
      expect(find.byType(ImmersiveKaraokeSweepText), findsOneWidget);
      expect(SchedulerBinding.instance.transientCallbackCount, greaterThan(0));
      // 默认不展示罗马音注音。
      expect(find.byKey(const ValueKey('lyric_line_romaji_0')), findsNothing);
      expect(find.text('光之海'), findsOneWidget);

      // 1. 外部切换为暂停态 -> Ticker 立即停止，零后台空转。
      playing.value = false;
      await tester.pump();
      expect(SchedulerBinding.instance.transientCallbackCount, 0);

      // 2. 恢复播放 -> Ticker 重新启动。
      playing.value = true;
      await tester.pump();
      expect(SchedulerBinding.instance.transientCallbackCount, greaterThan(0));

      // 3. 页面切后台或不可见（TickerMode 关闭）-> Ticker 立即停止。
      tickerEnabled.value = false;
      await tester.pump();
      expect(SchedulerBinding.instance.transientCallbackCount, 0);

      // 4. 恢复可见并推移至本行窗口结束后，动画自然收尾，pumpAndSettle 安全返回。
      tickerEnabled.value = true;
      pos.value = const Duration(milliseconds: 12600);
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
      expect(SchedulerBinding.instance.transientCallbackCount, 0);
    });

    testWidgets('开启罗马音展示注音且不混入译文区，长行自动换行无异常且偏移实时前移', (tester) async {
      final pos = ValueNotifier<Duration>(const Duration(seconds: 10));
      final playing = ValueNotifier<bool>(false);
      addTearDown(pos.dispose);
      addTearDown(playing.dispose);

      const longLineLrc = '''
[00:10.00]どこまでも遠く響き渡る光の歌を今君と聴いているから
[00:10.00]此刻正与你一同聆听这响彻遥远彼端的光之歌
[00:10.00]roma:dokomademo tooku hibikiwataru hikari no uta wo ima kimi to kiiteiru kara
[00:20.00]次の行
''';
      final doc = LrcParser.parseText(longLineLrc);

      await tester.pumpWidget(
        wrapLyricsTestApp(
          child: SizedBox(
            width: 260,
            child: ImmersiveLyricLineLeaf(
              index: 0,
              line: doc.lines[0],
              activeLyricIndex: 0,
              positionListenable: pos,
              isPlayingListenable: playing,
              showRomaji: true,
              compact: false,
              userScrolling: false,
              lyricOffsetSeconds: 1.0,
              nextLineStartSeconds: 20.0,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('lyric_line_romaji_0')), findsOneWidget);
      final romaWidget = tester.widget<Text>(
        find.byKey(const ValueKey('lyric_line_romaji_0')),
      );
      expect(romaWidget.data, contains('dokomademo'));
      expect(find.text('此刻正与你一同聆听这响彻遥远彼端的光之歌'), findsOneWidget);
    });
  });

  group('ImmersiveLyricsViewport 拖拽定位时间轴与点击跳转', () {
    testWidgets('用户拖拽列表唤起时间轴引导线，点击播放图标触发偏移后跳转回调', (tester) async {
      final bundle = KonataDatabaseBundle.openInMemory();
      addTearDown(bundle.close);
      final prefsStore = LyricsPreferencesStore(
        ScopedPrefsStore(bundle.userState),
      );
      final pos = ValueNotifier<Duration>(const Duration(seconds: 11));
      final playing = ValueNotifier<bool>(false);
      addTearDown(pos.dispose);
      addTearDown(playing.dispose);

      double? seekTarget;
      bool? seekResume;
      final controller = LyricDisplayController(
        resolver: LyricsResolver(
          cacheRepository: StorageLyricCacheRepository.fromBundle(bundle),
          sourcesFactory: () async => const [],
        ),
        preferencesStore: prefsStore,
        positionListenable: pos,
        isPlayingListenable: playing,
        onSeekRequested: (targetSeconds, {resumePlayback = false}) {
          seekTarget = targetSeconds;
          seekResume = resumePlayback;
        },
      );
      addTearDown(controller.dispose);

      const multiLineLrc = '''
[00:10.00]第一句歌词起始
[00:20.00]第二句歌词继续
[00:30.00]第三句歌词高潮
[00:40.00]第四句歌词衔接
[00:50.00]第五句歌词尾声
[01:00.00]第六句歌词收尾
''';
      await controller.resolveForTrack(
        const LyricTrackQuery(
          trackKey: 'vp-track',
          albumKey: 'vp-album',
          title: '视口定位曲',
          artist: 'Tester',
          durationSeconds: 180.0,
          embeddedLrcText: multiLineLrc,
        ),
      );
      await controller.setTrackOffsetMillis(500);

      await tester.pumpWidget(
        wrapLyricsTestApp(
          child: SizedBox(
            width: 500,
            height: 460,
            child: ImmersiveLyricsViewport(
              itemId: 'vp-track',
              controller: controller,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // 向下拖动列表使后续歌词居中进入时间轴定位焦带。
      await tester.drag(
        find.byKey(const ValueKey('immersive_lyrics_list')),
        const Offset(0, -180),
      );
      await tester.pump();
      // 等待惯性停稳延迟使可点击定位按钮激活。
      await tester.pump(
        KonataPlaybackTokens.lyricScrollIdleSettleDelay +
            const Duration(milliseconds: 50),
      );

      expect(
        find.byKey(const ValueKey('lyric_timeline_scrub_guide')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('lyric_timeline_seek_play_button')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey('lyric_timeline_seek_play_button')),
      );
      await tester.pump();

      expect(seekTarget, isNotNull);
      expect(seekResume, isTrue);

      // 清理视口内的居中或空闲定时器，确保测试退出无悬挂计时器。
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });

    testWidgets('浅色系统主题下歌词仍保持纯白发光排版、无右下角漂浮胶囊且响应双语译文开关', (tester) async {
      final bundle = KonataDatabaseBundle.openInMemory();
      addTearDown(bundle.close);
      final prefsStore = LyricsPreferencesStore(
        ScopedPrefsStore(bundle.userState),
      );
      final pos = ValueNotifier<Duration>(const Duration(seconds: 10));
      final playing = ValueNotifier<bool>(false);
      addTearDown(pos.dispose);
      addTearDown(playing.dispose);

      final controller = LyricDisplayController(
        resolver: LyricsResolver(
          cacheRepository: StorageLyricCacheRepository.fromBundle(bundle),
          sourcesFactory: () async => const [],
        ),
        preferencesStore: prefsStore,
        positionListenable: pos,
        isPlayingListenable: playing,
      );
      addTearDown(controller.dispose);

      await controller.resolveForTrack(
        const LyricTrackQuery(
          trackKey: 'bilingual-light-guard',
          albumKey: 'bilingual-album',
          title: '双语测试曲',
          artist: 'Singer',
          durationSeconds: 180.0,
          embeddedLrcText: kSampleBilingualLrc,
        ),
      );

      await tester.pumpWidget(
        wrapLyricsTestApp(
          child: Theme(
            data: KonataTheme.lightTheme(),
            child: SizedBox(
              width: 480,
              height: 520,
              child: ImmersiveLyricsViewport(
                itemId: 'bilingual-light-guard',
                controller: controller,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // 视口保持 100% 纯净：绝不存在漂浮「译 / -0.2s / +0.2s」按钮或胶囊。
      expect(find.text('译'), findsNothing);
      expect(find.text('-0.2s'), findsNothing);
      expect(find.text('+0.2s'), findsNothing);

      // 浅色外部主题下，后续歌词行仍强制使用纯白字体而非深墨灰。
      final secondLineText = tester.widget<Text>(find.text('風の歌が今響いてる'));
      expect(secondLineText.style?.color, isNotNull);
      expect(secondLineText.style!.color!.r, greaterThan(0.95));
      expect(secondLineText.style!.color!.g, greaterThan(0.95));
      expect(secondLineText.style!.color!.b, greaterThan(0.95));

      // 双语译文初始展示，关闭 showTranslation 后立即隐藏译文行并保留原句。
      expect(find.text('风的歌声此刻正在回响'), findsOneWidget);
      controller.setShowTranslation(false);
      await tester.pump();
      expect(find.text('风的歌声此刻正在回响'), findsNothing);
      expect(find.text('風の歌が今響いてる'), findsOneWidget);

      controller.setShowTranslation(true);
      await tester.pump();
      expect(find.text('风的歌声此刻正在回响'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  });
}
