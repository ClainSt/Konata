import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'package:konata/application/playback/audio_playback_notifier.dart';
import 'package:konata/application/playback/playback_preferences_provider.dart';
import 'package:konata/application/providers/artwork_provider.dart';
import 'package:konata/application/providers/desktop_external_tools_providers.dart';
import 'package:konata/domain/models/external_player_config.dart';
import 'package:konata/domain/models/media_variant.dart';
import 'package:konata/domain/models/work.dart';
import 'package:konata/domain/playback/cue_and_lrc_parser.dart';
import 'package:konata/domain/playback/lyric_version_matcher.dart';
import 'package:konata/domain/playback/playback_probe_stats.dart';
import 'package:konata/presentation/audio/immersive_audio_page.dart';
import 'package:konata/presentation/audio/immersive_audio_sub_widgets.dart';
import 'package:konata/presentation/audio/immersive_karaoke_sweep_text.dart';
import 'package:konata/presentation/detail/detail_bottom_drawer.dart';
import 'package:konata/presentation/detail/work_detail_page.dart';
import 'package:konata/presentation/settings/settings_external_tools_panel.dart';
import 'package:konata/presentation/shell/adaptive_capsule_layout.dart';
import 'package:konata/presentation/theme/konata_playback_tokens.dart';
import 'package:konata/presentation/theme/konata_theme.dart';
import 'package:konata/presentation/widgets/design_system/konata_glass_capsule.dart';
import 'package:konata/presentation/widgets/design_system/konata_system_file_picker.dart';
import 'package:konata/presentation/widgets/playback/konata_cd_disc_placeholder.dart';
import 'package:konata/presentation/widgets/playback/konata_floating_mini_player.dart';
import 'package:konata/presentation/widgets/playback/konata_playback_capsule.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:konata/application/providers/konata_value_notifier.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final Uint8List _sample1x1Png = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

AudioQueueItem _makeTrack(String id, String title, {String album = 'CD'}) {
  final work = Work(id: 'w_$id', title: '测试作品');
  final variant = MediaVariant(
    id: 'v_$id',
    workId: 'w_$id',
    sourceId: 's1',
    relativePath: '$id.flac',
    fileName: '$id.flac',
    fileSize: 1024,
    assetKind: AssetKind.cdAlbum,
  );
  return AudioQueueItem(
    id: id,
    work: work,
    variant: variant,
    title: title,
    albumTitle: album,
  );
}

/// 轻量静态音频播放状态通知器（隔离真实 libmpv，便于验证歌词、小窗与进度扫光表现）。
class _TestAudioNotifier extends AudioPlaybackNotifier {
  _TestAudioNotifier(AudioPlaybackState initial) : super(initialState: initial);

  void setStateForTest(AudioPlaybackState next) {
    state = next;
  }
}

/// 空白桌面外部工具动作桩（记录自动保存不触及真实磁盘）。
class _FakeExternalToolsActions implements DesktopExternalToolsActions {
  List<ExternalPlayerConfig> saved = const [];

  @override
  Future<void> saveExternalPlayer(ExternalPlayerConfig config) async {
    saved = [config];
  }

  @override
  Future<void> saveExternalPlayers(
    Iterable<ExternalPlayerConfig> configs,
  ) async {
    saved = configs.toList(growable: false);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('v2 第二轮视觉与交互打磨 10 项验收回归', () {
    test('双语 LRC（网易云 lrc + tlyric 毫秒偏差）严格日文主行、中文副行，永不拼行或重复日文', () {
      const rawBilingual =
          '[01:20.40]泣いたり笑ったりしながら気づいた やっと\n'
          '[01:20.38]在一起哭泣和笑着，终于意识到\n'
          '[01:25.10]胸に張り付く絶望が 光になるまで\n'
          '[01:25.10]直到胸中的绝望变成光芒';

      expect(LyricVersionMatcher.hasExplicitEnhancedTags(rawBilingual), isFalse);

      final parsed = LrcParser.parseText(rawBilingual);
      expect(parsed.lines, hasLength(2));
      expect(
        parsed.lines[0].primaryText,
        equals('泣いたり笑ったりしながら気づいた やっと'),
      );
      expect(parsed.lines[0].secondaryLines, equals(['在一起哭泣和笑着，终于意识到']));
      expect(
        parsed.lines[1].primaryText,
        equals('胸に張り付く絶望が 光になるまで'),
      );
      expect(parsed.lines[1].secondaryLines, equals(['直到胸中的绝望变成光芒']));

      final spans = LyricVersionMatcher.parseActiveSpanLines(rawBilingual);
      expect(spans, hasLength(2));
      expect(spans[0].spans, hasLength(1));
      expect(
        spans[0].spans.first.text,
        equals('泣いたり笑ったりしながら気づいた やっと'),
      );
      expect(spans[0].translation, equals('在一起哭泣和笑着，终于意识到'));
    });

    testWidgets('展开态悬浮音频胶囊采用一体化轮廓进度绘制，无 LinearProgressIndicator 与白边夹缝', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        SharedPreferences.setMockInitialValues({});

        final track = _makeTrack(
          't1',
          'Chase the world',
          album: 'SPECIAL SAMPLER DISC',
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              audioPlaybackProvider.overrideWith(
                () => _TestAudioNotifier(
                  AudioPlaybackState(
                    isActive: true,
                    isPlaying: true,
                    currentIndex: 0,
                    queue: [track],
                    positionSeconds: 45,
                    durationSeconds: 180,
                  ),
                ),
              ),
              floatingMiniVisualStateProvider.overrideWith(
                () => KonataValueNotifier.value(
                  FloatingMiniVisualState.expanded,
                ),
              ),
            ],
            child: MaterialApp(
              theme: KonataTheme.lightTheme(),
              home: const Scaffold(
                body: Center(
                  child: KonataFloatingMiniPlayer.standalone(
                    kind: FloatingMiniPlayerKind.audio,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        expect(
          find.byKey(const ValueKey('floating_mini_audio_pill')),
          findsOneWidget,
        );
        expect(find.byType(LinearProgressIndicator), findsNothing);
        final capsule = tester.widget<KonataGlassCapsule>(
          find.byKey(const ValueKey('floating_mini_audio_pill')),
        );
        expect(capsule.showBorder, isFalse);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('深色模式下圆形音频小窗右下角跳动条呈黑色，且无封面显示实体光学 CD 光盘占位', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        SharedPreferences.setMockInitialValues({});

        final track = _makeTrack('t2', '无封面单曲');

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              audioPlaybackProvider.overrideWith(
                () => _TestAudioNotifier(
                  AudioPlaybackState(
                    isActive: true,
                    isPlaying: true,
                    currentIndex: 0,
                    queue: [track],
                    positionSeconds: 30,
                    durationSeconds: 200,
                  ),
                ),
              ),
              floatingMiniVisualStateProvider.overrideWith(
                () => KonataValueNotifier.value(
                  FloatingMiniVisualState.collapsed,
                ),
              ),
            ],
            child: MaterialApp(
              theme: KonataTheme.darkTheme(),
              home: const Scaffold(
                body: Center(
                  child: KonataFloatingMiniPlayer.standalone(
                    kind: FloatingMiniPlayerKind.audio,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        expect(find.byType(KonataCdDiscPlaceholder), findsOneWidget);
        final eqFinder = find.byKey(const ValueKey('floating_mini_audio_disc'));
        expect(eqFinder, findsOneWidget);
        final barContainers = tester.widgetList<Container>(
          find.descendant(of: eqFinder, matching: find.byType(Container)),
        );
        final hasDarkEqBar = barContainers.any((c) {
          final dec = c.decoration;
          return dec is BoxDecoration &&
              dec.color ==
                  KonataPlaybackTokens.floatingMiniDiscEqualizerDarkBar;
        });
        expect(hasDarkEqBar, isTrue);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('歌词开头即具备景深模糊、垂直居中起步、激活行大字号自然换行并启用卡拉 OK 进度扫白', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      try {
        SharedPreferences.setMockInitialValues({});

        const lrc = LrcDocument(
          lines: [
            LrcCueLine(
              startSeconds: 12,
              primaryText: '向き合えても会話しちゃくれない 長い一行の歌詞テスト',
              secondaryLines: ['即使面对面也不愿交谈'],
            ),
            LrcCueLine(
              startSeconds: 18,
              primaryText: 'ラブ・カルチャーは in the モニター',
            ),
            LrcCueLine(
              startSeconds: 24,
              primaryText: 'あの頃の神が愛おしくて',
            ),
          ],
        );
        final track = _makeTrack('t3', '65535', album: '16bit');

        late _TestAudioNotifier notifier;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              audioPlaybackProvider.overrideWith(() {
                notifier = _TestAudioNotifier(
                  AudioPlaybackState(
                    isActive: true,
                    isPlaying: false,
                    currentIndex: 0,
                    queue: [track],
                    positionSeconds: 5,
                    durationSeconds: 193,
                    lrcDocument: lrc,
                    activeLyricIndex: -1,
                  ),
                );
                return notifier;
              }),
              tmdbImageLoaderProvider.overrideWithValue(
                (_, {targetWidth, imageSize}) async => _sample1x1Png,
              ),
              immersiveAudioExpandedProvider.overrideWith(
                () => KonataValueNotifier.value(true),
              ),
            ],
            child: MaterialApp(
              locale: const Locale('zh', 'CN'),
              supportedLocales: const [Locale('zh', 'CN')],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              theme: KonataTheme.darkTheme(),
              home: const ImmersiveAudioPage(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // 1. 歌词列表自垂直居中起步，顶部留白 >= 96px
        final listView = tester.widget<ListView>(
          find.byKey(const ValueKey('immersive_lyrics_list')),
        );
        final padding = listView.padding! as EdgeInsets;
        expect(padding.top, greaterThanOrEqualTo(96.0));

        // 2. 前奏期（activeLyricIndex == -1）首行清晰就绪但暂不扫白，后续行逐级景深模糊
        final leafFinders = find.byType(ImmersiveLyricLineLeaf);
        expect(leafFinders, findsNWidgets(3));
        expect(
          find.byKey(const ValueKey('intro_standby_first_lyric')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('active_line_karaoke')),
          findsNothing,
        );
        expect(
          find.descendant(
            of: leafFinders.first,
            matching: find.byType(ImageFiltered),
          ),
          findsNothing,
        );
        expect(
          find.descendant(
            of: leafFinders.at(1),
            matching: find.byType(ImageFiltered),
          ),
          findsOneWidget,
        );

        // 3. 进入第 0 句演唱：激活行切换为大字号卡拉 OK 扫白组件且取消模糊
        notifier.setStateForTest(
          AudioPlaybackState(
            isActive: true,
            isPlaying: false,
            currentIndex: 0,
            queue: [track],
            positionSeconds: 15,
            durationSeconds: 193,
            lrcDocument: lrc,
            activeLyricIndex: 0,
          ),
        );
        await tester.pumpAndSettle();

        final sweepWidget = tester.widget<ImmersiveKaraokeSweepText>(
          find.byKey(const ValueKey('active_line_karaoke')),
        );
        expect(
          sweepWidget.litStyle.fontSize,
          equals(KonataPlaybackTokens.lyricActiveFontSize),
        );
        expect(
          KonataPlaybackTokens.lyricActiveFontSize,
          greaterThan(KonataPlaybackTokens.lyricInactiveFontSize * 1.6),
        );
        expect(
          find.descendant(
            of: leafFinders.first,
            matching: find.byType(ImageFiltered),
          ),
          findsNothing,
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('视频胶囊章节点：贴近第 4 章磁吸高亮并展示正确标题、开头章节点不被圆点遮挡、紧邻章节点去重且不阻挡点击', (
      tester,
    ) async {
      double? committedSeek;
      const total = 1422.0; // 23:42
      const chapters = [
        PlaybackChapter(index: 0, title: 'Chapter 01', startSeconds: 0),
        PlaybackChapter(index: 1, title: 'Chapter 02', startSeconds: 478),
        PlaybackChapter(index: 2, title: 'Chapter 03', startSeconds: 1180),
        PlaybackChapter(index: 3, title: 'Chapter 04', startSeconds: 1323),
        PlaybackChapter(index: 4, title: 'Chapter 05', startSeconds: 1330),
      ];

      await tester.pumpWidget(
        MaterialApp(
          theme: KonataTheme.lightTheme(),
          home: Scaffold(
            body: Center(
              child: KonataPlaybackCapsule(
                maxWidth: 800,
                positionSeconds: 299,
                durationSeconds: total,
                isPlaying: true,
                onTogglePlayPause: () {},
                onSeek: (sec) => committedSeek = sec,
                chapters: chapters,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Chapter 04 (1323s) 与 Chapter 05 (1330s) 间距 < 12px：常态自动抑制紧邻重叠点
      expect(
        find.byKey(const ValueKey('konata_chapter_diamond_3')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('konata_chapter_diamond_4')),
        findsNothing,
      );

      // 悬停在 22:00（1320s，位于 Chapter 04 起点 1323s 左侧约 1.5px 处）：必须磁吸高亮 Chapter 04 而非 Chapter 03
      final capsuleBox = tester.getRect(find.byType(KonataPlaybackCapsule));
      const inset = KonataPlaybackTokens.capsuleProgressHorizontalInset;
      final barSpan = capsuleBox.width - inset * 2;
      final hoverAt2200 = Offset(
        capsuleBox.left + inset + (1320.0 / total) * barSpan,
        capsuleBox.top +
            KonataPlaybackTokens.capsuleProgressTopInset +
            KonataPlaybackTokens.capsuleProgressRestHeight * 0.5,
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await tester.pump();
      await mouse.moveTo(hoverAt2200);
      await tester.pumpAndSettle();

      expect(find.textContaining('Chapter 04'), findsOneWidget);
      expect(find.textContaining('Chapter 03'), findsNothing);

      // 每个菱形均包裹 IgnorePointer 且点击进度条可正常触发 seek
      final d3 = find.byKey(const ValueKey('konata_chapter_diamond_3'));
      expect(
        find.descendant(of: d3, matching: find.byType(IgnorePointer)),
        findsOneWidget,
      );
      await tester.tapAt(hoverAt2200);
      await tester.pump();
      expect(committedSeek, isNotNull);
      expect(committedSeek!, closeTo(1320.0, 12.0));
    });

    testWidgets('外部调用设置面板移除冗余的（当前首选）/（备选）后缀', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            desktopExternalPlayersProvider.overrideWith((_) async => const []),
            desktopExternalToolsActionsProvider.overrideWithValue(
              _FakeExternalToolsActions(),
            ),
          ],
          child: MaterialApp(
            theme: KonataTheme.lightTheme(),
            home: const Scaffold(
              body: SingleChildScrollView(
                child: SettingsExternalToolsPanel(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('MPV 可执行文件路径'), findsOneWidget);
      expect(find.text('PotPlayer 可执行文件路径'), findsOneWidget);
      expect(find.textContaining('当前首选'), findsNothing);
      expect(find.textContaining('备选'), findsNothing);
    });

    test('KonataSystemFilePicker 单飞互斥锁拦截并发重入并启用 Windows 模态锁定', () async {
      var openCalls = 0;
      WindowsOptions? capturedWinOptions;
      final gate = Completer<List<PlatformFile>>();

      final picker = KonataSystemFilePicker(
        pickFilesImpl: ({
          dialogTitle,
          initialDirectory,
          type = FileType.any,
          allowedExtensions,
          windowsOptions = const WindowsOptions(),
        }) {
          openCalls++;
          capturedWinOptions = windowsOptions;
          return gate.future;
        },
      );

      final firstCall = picker.pickFiles(dialogTitle: '选择 MPV');
      expect(picker.isDialogOpen, isTrue);

      // 并发连续点击 3 次均被拦截，不会再弹出新的系统窗口
      final second = await picker.pickFiles(dialogTitle: '选择 MPV');
      final third = await picker.pickFiles(dialogTitle: '选择 PotPlayer');
      expect(second, isEmpty);
      expect(third, isEmpty);
      expect(openCalls, equals(1));
      expect(capturedWinOptions?.lockParentWindow, isTrue);

      gate.complete(const <PlatformFile>[]);
      await firstCall;
      expect(picker.isDialogOpen, isFalse);

      // 关闭旧窗口后可再次正常打开
      final nextPicker = KonataSystemFilePicker(
        getDirectoryPathImpl: ({
          dialogTitle,
          initialDirectory,
          windowsOptions = const WindowsOptions(),
        }) async {
          capturedWinOptions = windowsOptions;
          return r'D:\Anime';
        },
      );
      final dir = await nextPicker.getDirectoryPath(dialogTitle: '选择目录');
      expect(dir, equals(r'D:\Anime'));
      expect(capturedWinOptions?.lockParentWindow, isTrue);
    });

    test('KonataSystemFilePicker Windows 走同线程原生通道选文件/目录/保存且避免跨线程死锁', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final calls = <MethodCall>[];
      final tempDir = await Directory.systemTemp.createTemp('konata_picker_');
      addTearDown(() async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              KonataSystemFilePicker.windowsMethodChannel,
              null,
            );
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final sampleSub = File(p.join(tempDir.path, 'ep01.ass'));
      await sampleSub.writeAsString('[Script Info]\nTitle: Test\n');
      final saveOutPath = p.join(tempDir.path, 'exported_log.txt');

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            KonataSystemFilePicker.windowsMethodChannel,
            (MethodCall call) async {
              calls.add(call);
              switch (call.method) {
                case 'pickFiles':
                  return <String>[sampleSub.path];
                case 'pickDirectory':
                  return tempDir.path;
                case 'saveFile':
                  return saveOutPath;
                default:
                  return null;
              }
            },
          );

      final picker = KonataSystemFilePicker(useWindowsNativeBridge: true);
      final picked = await picker.pickFiles(
        dialogTitle: '选择外挂字幕文件',
        type: FileType.custom,
        allowedExtensions: const <String>['ass', 'srt'],
        allowMultiple: false,
      );
      expect(picked, hasLength(1));
      expect(picked.first.path, equals(sampleSub.path));
      expect(picked.first.name, equals('ep01.ass'));
      expect(calls.last.method, equals('pickFiles'));
      final pickArgs = Map<Object?, Object?>.from(
        calls.last.arguments as Map<Object?, Object?>,
      );
      expect(pickArgs['allowMultiple'], isFalse);
      expect(pickArgs['allowedExtensions'], equals(<String>['ass', 'srt']));

      final pickedDir = await picker.getDirectoryPath(dialogTitle: '选择本地动画媒体目录');
      expect(pickedDir, equals(tempDir.path));
      expect(calls.last.method, equals('pickDirectory'));

      final savedUri = await picker.saveFile(
        fileName: 'exported_log.txt',
        bytes: Uint8List.fromList('konata-log'.codeUnits),
        dialogTitle: '导出日志',
      );
      expect(savedUri, equals(Uri.file(saveOutPath)));
      expect(await File(saveOutPath).readAsString(), equals('konata-log'));
      expect(calls.last.method, equals('saveFile'));
    });

    testWidgets('详情页退出后自动重置抽屉展开与分页状态，再次进入其他作品默认收起', (
      tester,
    ) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Builder(
              builder: (ctx) => Scaffold(
                body: ElevatedButton(
                  onPressed: () {
                    Navigator.of(ctx).push(
                      MaterialPageRoute<void>(
                        builder: (_) => Consumer(
                          builder: (_, ref, _) {
                            final expanded = ref.watch(
                              detailDrawerExpandedProvider,
                            );
                            final tab = ref.watch(detailDrawerTabProvider);
                            return Scaffold(
                              body: Column(
                                children: [
                                  Text('state:$expanded:${tab.name}'),
                                  ElevatedButton(
                                    onPressed: () {
                                      ref
                                              .read(
                                                detailDrawerExpandedProvider
                                                    .notifier,
                                              )
                                              .state =
                                          true;
                                      ref
                                              .read(
                                                detailDrawerTabProvider
                                                    .notifier,
                                              )
                                              .state =
                                          DetailDrawerTab.extra;
                                    },
                                    child: const Text('OPEN_EXTRAS'),
                                  ),
                                  ElevatedButton(
                                    onPressed: () => Navigator.of(ctx).pop(),
                                    child: const Text('POP_DETAIL'),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                    );
                  },
                  child: const Text('ENTER_DETAIL'),
                ),
              ),
            ),
          ),
        ),
      );

      // 首次进入作品 A 并展开「特典」
      await tester.tap(find.text('ENTER_DETAIL'));
      await tester.pumpAndSettle();
      expect(find.text('state:false:main'), findsOneWidget);
      await tester.tap(find.text('OPEN_EXTRAS'));
      await tester.pumpAndSettle();
      expect(find.text('state:true:extra'), findsOneWidget);

      // 退出详情页后再次进入作品 B：必须重置回默认收起与正片分页
      await tester.tap(find.text('POP_DETAIL'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ENTER_DETAIL'));
      await tester.pumpAndSettle();
      expect(find.text('state:false:main'), findsOneWidget);
    });
  });
}
