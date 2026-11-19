import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ccplayer/application/playback/audio_playback_notifier.dart';
import 'package:ccplayer/application/playback/playback_preferences_provider.dart';
import 'package:ccplayer/application/providers/library_providers.dart';
import 'package:ccplayer/domain/models/media_source.dart';
import 'package:ccplayer/domain/models/media_variant.dart';
import 'package:ccplayer/domain/models/work.dart';
import 'package:ccplayer/domain/playback/playback_probe_stats.dart';
import 'package:ccplayer/domain/playback/track_preferences.dart';
import 'package:ccplayer/infrastructure/database/drift_library_repository.dart';
import 'package:ccplayer/infrastructure/database/konata_database.dart';
import 'package:ccplayer/infrastructure/players/libmpv_ffi.dart';
import 'package:ccplayer/infrastructure/storage/storage_root_provider.dart';
import 'package:ccplayer/presentation/audio/mini_audio_bar.dart';
import 'package:ccplayer/presentation/theme/konata_theme.dart';
import 'package:ccplayer/presentation/widgets/design_system/konata_toast.dart';

class _ControlledAudioMpvClient implements LibMpvClient {
  final Map<String, String> options = {};
  final List<List<String>> commands = [];
  final Map<String, double> doubles = {};
  final Map<String, String> strings = {'audio-codec-name': 'flac'};
  final Map<String, int> ints = {
    'audio-params/samplerate': 48000,
    'audio-bitrate': 1024000,
  };
  final StreamController<MpvClientEvent> _events =
      StreamController<MpvClientEvent>.broadcast();

  int _nextEntryId = 0;

  /// 自定义每次 `loadfile` 的响应策略（传入目标路径与分配的递增 playlistEntryId）。
  void Function(
    _ControlledAudioMpvClient client,
    String target,
    int playlistEntryId,
  )?
  onLoadFile;

  @override
  bool isInitialized = false;

  @override
  bool isDisposed = false;

  @override
  int get handleAddress => 91;

  @override
  Stream<MpvClientEvent> get events => _events.stream;

  void emitEvent(MpvClientEvent event) {
    if (!_events.isClosed) {
      _events.add(event);
    }
  }

  @override
  String errorString(int code) => MpvError.describeAudioError(code);

  @override
  int setOptionString(String name, String value) {
    options[name] = value;
    return 0;
  }

  @override
  int initialize() {
    isInitialized = true;
    return 0;
  }

  @override
  int command(List<String> args) {
    commands.add(List<String>.from(args));
    if (args.isNotEmpty && args.first == 'loadfile') {
      final entryId = ++_nextEntryId;
      final target = args[1];
      if (onLoadFile != null) {
        onLoadFile!(this, target, entryId);
      } else {
        scheduleMicrotask(() {
          emitEvent(MpvStartFileEvent(entryId));
          emitEvent(const MpvFileLoadedEvent());
          emitEvent(const MpvPlaybackRestartEvent());
        });
      }
    }
    return 0;
  }

  @override
  int commandAsync(int replyUserdata, List<String> args) => command(args);

  @override
  Future<void> dispose() async {
    isDisposed = true;
    if (!_events.isClosed) {
      await _events.close();
    }
  }

  @override
  bool? getPropertyFlag(String name) => false;

  @override
  double? getPropertyDouble(String name) => doubles[name];

  @override
  int? getPropertyInt64(String name) => ints[name];

  @override
  String? getPropertyString(String name) => strings[name];

  @override
  int observeProperty(int replyUserdata, String name, int format) => 0;

  @override
  List<MpvAudioDevice> readAudioDeviceList() => const [];

  @override
  List<MpvSeekableRange> readDemuxerSeekableRanges() => const [];

  @override
  List<PlaybackChapter> readChapterList({double? totalDurationSeconds}) =>
      const [];

  @override
  List<MpvTrackInfo> readTrackList() => const [];

  @override
  int requestLogMessages(String minLevel) => 0;

  @override
  int setPropertyDouble(String name, double value) {
    doubles[name] = value;
    return 0;
  }

  @override
  int setPropertyFlag(String name, bool value) => 0;

  @override
  int setPropertyInt64(String name, int value) => 0;

  @override
  int setPropertyString(String name, String value) {
    strings[name] = value;
    if (name == 'start' && value == 'none') {
      doubles.remove('start');
    }
    return 0;
  }
}

void main() {
  group('阶段 2 · 音频 -16 根因修复、重试跳曲与 20 连切零报错回归测试', () {
    late Directory tempRoot;

    setUpAll(() {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    });

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      tempRoot = await Directory.systemTemp.createTemp('konata_r4_stage2_');
    });

    tearDown(() async {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      try {
        if (await tempRoot.exists()) {
          await tempRoot.delete(recursive: true);
        }
      } on FileSystemException catch (e) {
        // Windows 下媒体句柄异步释放时偶发短暂文件占用，记录后继续后续用例清理。
        debugPrint('清理临时测试目录延迟释放：${e.message}');
      }
    });

    test('19a. MpvError.describeAudioError(-16) 文案准确，且每次装填前复位 aid=auto / vid=no / sid=no', () async {
      expect(
        MpvError.describeAudioError(MpvError.nothingToPlay),
        equals('未找到可播放音轨或音频流未被选中 (code: -16)'),
      );
      expect(
        MpvError.describeAudioError(MpvError.nothingToPlay),
        isNot(contains('读取或解码中断')),
      );

      final trackFile = File(p.join(tempRoot.path, '01.flac'));
      await trackFile.writeAsBytes([1, 2, 3, 4]);

      final fakeClient = _ControlledAudioMpvClient();
      // 模拟残留的错误轨道编号与裁剪边界
      fakeClient.strings['aid'] = '3';
      fakeClient.strings['vid'] = '1';
      fakeClient.strings['sid'] = '2';
      fakeClient.strings['end'] = '12.0';

      final container = ProviderContainer(
        overrides: [
          storageRootProvider.overrideWithValue(
            StorageRootService(overrideRoot: tempRoot),
          ),
          libraryRepositoryProvider.overrideWith((ref) {
            final db = KonataDatabase(NativeDatabase.memory());
            ref.onDispose(db.close);
            return DriftLibraryRepository(db);
          }),
          playbackPreferencesProvider.overrideWith(
            (_) => PlaybackPreferencesNotifier(enablePersistence: false),
          ),
          audioPlaybackProvider.overrideWith(
            (ref) => AudioPlaybackNotifier(
              ref,
              clientFactory: () => fakeClient,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      const work = Work(id: 'w1', title: '测试专辑');
      final source = MediaSource(
        id: 's1',
        kind: MediaSourceKind.local,
        label: '本地',
        location: tempRoot.path,
        createdAt: DateTime(2026, 1, 1),
      );
      const v1 = MediaVariant(
        id: 'v1',
        workId: 'w1',
        sourceId: 's1',
        relativePath: '01.flac',
        fileName: '01.flac',
        fileSize: 4,
        assetKind: AssetKind.cdAlbum,
      );

      await container.read(audioPlaybackProvider.notifier).playCdCollection(
        work: work,
        cdVariants: const [v1],
        initialVariant: v1,
        sourcesById: {'s1': source},
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(fakeClient.strings['aid'], equals('auto'));
      expect(fakeClient.strings['vid'], equals('no'));
      expect(fakeClient.strings['sid'], equals('no'));
      expect(fakeClient.strings['end'], equals('none'));
      expect(container.read(audioPlaybackProvider).isPlaying, isTrue);
      expect(container.read(audioPlaybackProvider).errorMessage, isNull);
    });

    test('19b. 偶发 -16 先静默重试最多 3 次；仍失败时自动跳至下一首并提示，不中断队列', () async {
      final f1 = File(p.join(tempRoot.path, '01_bad.flac'));
      final f2 = File(p.join(tempRoot.path, '02_transient.flac'));
      final f3 = File(p.join(tempRoot.path, '03_good.flac'));
      await f1.writeAsBytes([1]);
      await f2.writeAsBytes([2]);
      await f3.writeAsBytes([3]);

      final loadAttemptsByBase = <String, int>{};
      final fakeClient = _ControlledAudioMpvClient()
        ..onLoadFile = (client, target, entryId) {
          final base = p.basename(target);
          final count = (loadAttemptsByBase[base] ?? 0) + 1;
          loadAttemptsByBase[base] = count;
          scheduleMicrotask(() {
            client.emitEvent(MpvStartFileEvent(entryId));
            if (base == '01_bad.flac') {
              // 持续返回 -16（初始 1 次 + 3 次重试 = 共 4 次）
              client.emitEvent(
                MpvEndFileEvent(
                  reason: MpvEndFileReason.error,
                  errorCode: MpvError.nothingToPlay,
                  playlistEntryId: entryId,
                ),
              );
              return;
            }
            if (base == '02_transient.flac' && count <= 2) {
              // 前两次偶发 -16，第 2 次静默重试（总第 3 次装填）成功恢复
              client.emitEvent(
                MpvEndFileEvent(
                  reason: MpvEndFileReason.error,
                  errorCode: MpvError.nothingToPlay,
                  playlistEntryId: entryId,
                ),
              );
              return;
            }
            client.emitEvent(const MpvFileLoadedEvent());
            client.emitEvent(const MpvPlaybackRestartEvent());
          });
        };

      final emittedErrors = <String>[];
      final container = ProviderContainer(
        overrides: [
          storageRootProvider.overrideWithValue(
            StorageRootService(overrideRoot: tempRoot),
          ),
          libraryRepositoryProvider.overrideWith((ref) {
            final db = KonataDatabase(NativeDatabase.memory());
            ref.onDispose(db.close);
            return DriftLibraryRepository(db);
          }),
          playbackPreferencesProvider.overrideWith(
            (_) => PlaybackPreferencesNotifier(enablePersistence: false),
          ),
          audioPlaybackProvider.overrideWith(
            (ref) => AudioPlaybackNotifier(
              ref,
              clientFactory: () => fakeClient,
              retryDelayBuilder: (_) => Duration.zero,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      container.listen<String?>(
        audioPlaybackProvider.select((s) => s.errorMessage),
        (prev, next) {
          if (next != null && next.isNotEmpty) {
            emittedErrors.add(next);
          }
        },
      );

      const work = Work(id: 'w1', title: '测试专辑');
      final source = MediaSource(
        id: 's1',
        kind: MediaSourceKind.local,
        label: '本地',
        location: tempRoot.path,
        createdAt: DateTime(2026, 1, 1),
      );
      final variants = [
        const MediaVariant(
          id: 'v1',
          workId: 'w1',
          sourceId: 's1',
          relativePath: '01_bad.flac',
          fileName: '01_bad.flac',
          fileSize: 1,
          assetKind: AssetKind.cdAlbum,
        ),
        const MediaVariant(
          id: 'v2',
          workId: 'w1',
          sourceId: 's1',
          relativePath: '02_transient.flac',
          fileName: '02_transient.flac',
          fileSize: 1,
          assetKind: AssetKind.cdAlbum,
        ),
        const MediaVariant(
          id: 'v3',
          workId: 'w1',
          sourceId: 's1',
          relativePath: '03_good.flac',
          fileName: '03_good.flac',
          fileSize: 1,
          assetKind: AssetKind.cdAlbum,
        ),
      ];

      await container.read(audioPlaybackProvider.notifier).playCdCollection(
        work: work,
        cdVariants: variants,
        initialVariant: variants.first,
        sourcesById: {'s1': source},
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));

      // 第 1 首尝试 1 + 3 次重试 = 4 次后跳往第 2 首；第 2 首偶发失败 2 次后静默恢复成功播放！
      expect(loadAttemptsByBase['01_bad.flac'], equals(4));
      expect(loadAttemptsByBase['02_transient.flac'], equals(3));
      expect(container.read(audioPlaybackProvider).currentIndex, equals(1));
      expect(container.read(audioPlaybackProvider).isPlaying, isTrue);
      // 仅第 1 首最终失败时发出过 1 次跳曲错误通知，第 2 首的瞬态重试全程静默零报错
      expect(emittedErrors, hasLength(1));
      expect(emittedErrors.single, contains('code: -16'));
      expect(emittedErrors.single, contains('已跳至下一首'));
    });

    test('19c. 连续快速切歌 20 次（含旧流延迟抛回 -16 竞态）零报错稳定起播', () async {
      final variants = <MediaVariant>[];
      for (var i = 1; i <= 6; i++) {
        final name = '${i.toString().padLeft(2, '0')}.flac';
        await File(p.join(tempRoot.path, name)).writeAsBytes([i]);
        variants.add(
          MediaVariant(
            id: 'v$i',
            workId: 'w1',
            sourceId: 's1',
            relativePath: name,
            fileName: name,
            fileSize: 1,
            assetKind: AssetKind.cdAlbum,
          ),
        );
      }

      int latestIssuedEntry = 0;
      final fakeClient = _ControlledAudioMpvClient()
        ..onLoadFile = (client, target, entryId) {
          final previousEntry = latestIssuedEntry;
          latestIssuedEntry = entryId;
          client.emitEvent(MpvStartFileEvent(entryId));
          if (previousEntry > 0) {
            // 模拟被切走的上一首旧流延迟推回 -16 错误事件
            scheduleMicrotask(() {
              client.emitEvent(
                MpvEndFileEvent(
                  reason: MpvEndFileReason.error,
                  errorCode: MpvError.nothingToPlay,
                  playlistEntryId: previousEntry,
                ),
              );
            });
          }
          Future<void>.delayed(const Duration(milliseconds: 2), () {
            if (entryId == latestIssuedEntry && !client.isDisposed) {
              client.emitEvent(const MpvFileLoadedEvent());
              client.emitEvent(const MpvPlaybackRestartEvent());
            }
          });
        };

      final emittedErrors = <String>[];
      final container = ProviderContainer(
        overrides: [
          storageRootProvider.overrideWithValue(
            StorageRootService(overrideRoot: tempRoot),
          ),
          libraryRepositoryProvider.overrideWith((ref) {
            final db = KonataDatabase(NativeDatabase.memory());
            ref.onDispose(db.close);
            return DriftLibraryRepository(db);
          }),
          playbackPreferencesProvider.overrideWith(
            (_) => PlaybackPreferencesNotifier(enablePersistence: false),
          ),
          audioPlaybackProvider.overrideWith(
            (ref) => AudioPlaybackNotifier(
              ref,
              clientFactory: () => fakeClient,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      container.listen<String?>(
        audioPlaybackProvider.select((s) => s.errorMessage),
        (_, next) {
          if (next != null && next.isNotEmpty) {
            emittedErrors.add(next);
          }
        },
      );

      const work = Work(id: 'w1', title: '连切压力专辑');
      final source = MediaSource(
        id: 's1',
        kind: MediaSourceKind.local,
        label: '本地',
        location: tempRoot.path,
        createdAt: DateTime(2026, 1, 1),
      );

      final notifier = container.read(audioPlaybackProvider.notifier);
      await notifier.playCdCollection(
        work: work,
        cdVariants: variants,
        initialVariant: variants.first,
        sourcesById: {'s1': source},
      );

      // 连续 20 次切歌
      for (var step = 0; step < 20; step++) {
        await notifier.next();
      }
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(emittedErrors, isEmpty);
      expect(container.read(audioPlaybackProvider).errorMessage, isNull);
      expect(container.read(audioPlaybackProvider).isPlaying, isTrue);
      expect(
        container.read(audioPlaybackProvider).currentIndex,
        equals(20 % variants.length),
      );
    });
  });

  group('阶段 2 · 公共底部悬浮 Toast 防跳位、避让悬浮小窗与 4 秒自动消失测试', () {
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('20. Toast 固定在底部安全区上方，滚动与路由切页零跳位，避开悬浮小窗，4s 自动淡出且支持 × 立即关闭', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        tester.view.viewPadding = const FakeViewPadding(top: 44, bottom: 24);
        tester.view.padding = const FakeViewPadding(top: 44, bottom: 24);
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          tester.view.resetViewPadding();
          tester.view.resetPadding();
        });

        final scrollController = ScrollController();
        addTearDown(scrollController.dispose);
        late BuildContext pageContext;

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              konataDatabaseProvider.overrideWith((ref) {
                final db = KonataDatabase(NativeDatabase.memory());
                ref.onDispose(db.close);
                return db;
              }),
              playbackPreferencesProvider.overrideWith(
                (_) => PlaybackPreferencesNotifier(enablePersistence: false),
              ),
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
              builder: (context, child) => MiniAudioOverlayHost(
                child: child ?? const SizedBox.shrink(),
              ),
              home: Scaffold(
                body: Builder(
                  builder: (context) {
                    pageContext = context;
                    return ListView.builder(
                      controller: scrollController,
                      itemCount: 40,
                      itemBuilder: (_, idx) => SizedBox(
                        height: 60,
                        child: Text('列表条目 $idx'),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        showKonataToast(pageContext, '网络请求超时，已自动降级', isError: true);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 220));

        final capsuleFinder = find.byKey(const ValueKey('konata_toast_capsule'));
        expect(capsuleFinder, findsOneWidget);
        final initialRect = tester.getRect(capsuleFinder);

        // 1. 滚动页面列表，Toast 位置纹丝不动
        scrollController.jumpTo(600);
        await tester.pump();
        expect(tester.getRect(capsuleFinder), equals(initialRect));

        // 2. 推入新页面路由，Toast 不随页面切换漂移或消失
        unawaited(
          Navigator.of(pageContext).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Center(child: Text('二级页面'))),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        final afterRouteRect = tester.getRect(capsuleFinder);
        // 推入二级页隐藏主导航后仍稳居底部安全区上方，不会跳到屏幕顶部或正中
        expect(afterRouteRect.bottom, lessThanOrEqualTo(844 - 24));
        expect(afterRouteRect.top, greaterThan(600));

        // 3. 悬浮小窗落入底部重叠区时，Toast 自动抬升避开小窗
        const simulatedMiniRect = Rect.fromLTWH(210, 680, 164, 92);
        ProviderScope.containerOf(pageContext, listen: false)
            .read(konataToastControllerProvider)
            .floatingMiniWindowRect
            .value = simulatedMiniRect;
        await tester.pump();
        final avoidedRect = tester.getRect(capsuleFinder);
        expect(
          avoidedRect.bottom,
          lessThanOrEqualTo(simulatedMiniRect.top - 10.0),
        );

        // 4. 校验 × 关闭热区 >= 48dp 并测试 4 秒自动消失
        final closeFinder = find.byKey(const ValueKey('konata_toast_close'));
        final closeRect = tester.getRect(closeFinder);
        expect(closeRect.width, greaterThanOrEqualTo(48.0));
        expect(closeRect.height, greaterThanOrEqualTo(48.0));

        // 剩余时间走满 4 秒自动淡出
        await tester.pump(const Duration(seconds: 4));
        await tester.pumpAndSettle();
        expect(capsuleFinder, findsNothing);

        // 5. 再次弹出并验证点击 × 立即关闭
        showKonataToast(pageContext, '手动立即关闭测试', isError: true);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 220));
        expect(find.text('手动立即关闭测试'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('konata_toast_close')));
        await tester.pumpAndSettle();
        expect(find.text('手动立即关闭测试'), findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
