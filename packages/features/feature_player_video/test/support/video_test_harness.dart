import 'dart:async';
import 'dart:io';

import 'package:engine_playback/engine_playback.dart';
import 'package:feature_player_video/feature_player_video.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';
import 'package:konata_storage/konata_storage.dart';
import 'package:path/path.dart' as p;

/// 测试专用临时便携存储根目录端口实现。
final class TempStorageRootPort implements StorageRootPort {
  /// 基于系统临时目录创建隔离测试根目录。
  TempStorageRootPort(this.rootDir);

  /// 临时根目录句柄。
  final Directory rootDir;

  @override
  Future<String> resolveAppRootPath() async => rootDir.path;

  @override
  Future<String> ensureUserdataDirPath() async {
    final dir = Directory(p.join(rootDir.path, StoragePathNames.userdataDir));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir.path;
  }

  @override
  Future<String> ensureDatabaseDirPath() async {
    final ud = await ensureUserdataDirPath();
    final dir = Directory(p.join(ud, StoragePathNames.dbSubdir));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir.path;
  }

  @override
  Future<String> resolveDatabaseFilePath(String dbFileName) async {
    final dir = await ensureDatabaseDirPath();
    return p.join(dir, dbFileName);
  }

  @override
  Future<String> ensureLogsDirPath() async {
    final ud = await ensureUserdataDirPath();
    final dir = Directory(p.join(ud, StoragePathNames.logsSubdir));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir.path;
  }

  @override
  Future<String> resolvePhotosDirPath() async {
    final dir = Directory(p.join(rootDir.path, StoragePathNames.photosDir));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir.path;
  }

  @override
  Future<String> ensureTempDirPath() async {
    final cache = await resolveCacheRootPath();
    final dir = Directory(p.join(cache, StoragePathNames.tempSubdir));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir.path;
  }

  @override
  Future<String> resolveCacheRootPath() async {
    final dir = Directory(p.join(rootDir.path, StoragePathNames.cacheDir));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir.path;
  }
}

/// 记录宿主窗口、全屏、置顶及迷你小窗调用状态的测试替身。
final class FakePlaybackHostWindowPort implements PlaybackHostWindowPort {
  bool fullScreen = false;
  bool alwaysOnTop = false;
  bool keepScreenOn = false;
  bool preferredLandscape = false;
  bool desktopMiniMode = false;
  ({double width, double height})? lastMiniSize;

  @override
  Future<bool> isFullScreen() async => fullScreen;

  @override
  Future<void> setFullScreen(bool enable) async {
    fullScreen = enable;
  }

  @override
  Future<void> setAlwaysOnTop(bool enable) async {
    alwaysOnTop = enable;
  }

  @override
  Future<void> enterDesktopMiniWindow({
    required double width,
    required double height,
  }) async {
    desktopMiniMode = true;
    lastMiniSize = (width: width, height: height);
  }

  @override
  Future<void> exitDesktopMiniWindow() async {
    desktopMiniMode = false;
  }

  @override
  Future<void> setKeepScreenOn(bool enable) async {
    keepScreenOn = enable;
  }

  @override
  Future<void> setPreferredLandscape(bool landscape) async {
    preferredLandscape = landscape;
  }
}

/// 可控跨模块导航记录替身。
final class FakeVideoNavigator implements AppNavigator {
  int popCount = 0;

  @override
  Future<void> switchNavSection(String sectionId) async {}

  @override
  Future<void> openWorkDetail(WorkId workId, {String? initialTabId}) async {}

  @override
  Future<void> openVideoPlayer({
    required WorkId workId,
    EpisodeId? episodeId,
    VariantId? variantId,
  }) async {}

  @override
  Future<void> openAudioPlayer({
    required WorkId workId,
    VariantId? variantId,
  }) async {}

  @override
  Future<void> openSettings({String? sectionId}) async {}

  @override
  Future<bool> pop() async {
    popCount++;
    return true;
  }
}

/// 可配置路径返回的跨端文件选择器替身。
final class FakeVideoFilePicker implements FilePickerPort {
  String? nextDirectory;
  String? nextImage;
  String? nextSubtitle;

  @override
  Future<String?> pickDirectory({String? dialogTitle}) async => nextDirectory;

  @override
  Future<String?> pickImageFile({String? dialogTitle}) async => nextImage;

  @override
  Future<String?> pickSubtitleFile({String? dialogTitle}) async => nextSubtitle;
}

/// 记录浏览器外链跳转请求的测试替身。
final class FakeUrlOpener implements UrlOpenerPort {
  final List<Uri> openedUris = <Uri>[];
  bool result = true;

  @override
  Future<bool> openExternalUrl(Uri uri) async {
    openedUris.add(uri);
    return result;
  }
}

/// 内存中收集结构化诊断日志条目的轻量测试端口。
final class FakeDiagnosticLogPort implements DiagnosticLogPort {
  final List<String> messages = <String>[];
  bool _verbose = false;

  @override
  bool get verboseEnabled => _verbose;

  @override
  DiagnosticSummaryCounts get summaryCounts => const DiagnosticSummaryCounts(
    totalEvents: 0,
    warningCount: 0,
    errorCount: 0,
    breadcrumbCount: 0,
  );

  @override
  void setVerbose(bool enabled) {
    _verbose = enabled;
  }

  @override
  void logEvent({
    required DiagnosticSubsystem subsystem,
    required String code,
    required String message,
    DiagnosticSeverity severity = DiagnosticSeverity.info,
    String? source,
    Map<String, Object?> context = const <String, Object?>{},
    Object? error,
    StackTrace? stackTrace,
  }) {
    messages.add('[$code] $message');
  }

  @override
  void logError({
    required DiagnosticSubsystem subsystem,
    required String code,
    required String message,
    required Object error,
    StackTrace? stackTrace,
    DiagnosticSeverity severity = DiagnosticSeverity.error,
    String? source,
    Map<String, Object?> context = const <String, Object?>{},
  }) {
    messages.add('[$code:error] $message ($error)');
  }

  @override
  void recordBreadcrumb({
    required String category,
    required String label,
    String? source,
    String? detail,
  }) {}

  @override
  void Function() registerSnapshotContributor(
    String sectionId,
    DiagnosticSnapshotContributor contributor,
  ) => () {};

  @override
  List<DiagnosticFaultSummary> summarizeFaults() =>
      const <DiagnosticFaultSummary>[];

  @override
  List<DiagnosticEvent> snapshotEvents() => const <DiagnosticEvent>[];

  @override
  Future<String> buildJsonBundle() async => '{}';

  @override
  Future<String> buildTextReport() async => '';

  @override
  void clear() {
    messages.clear();
  }
}

/// 空桌面流媒体网关工厂替身。
final class FakeGatewayFactory implements MediaSourceGatewayFactoryPort {
  @override
  Future<MediaSourceGateway> create(
    MediaSourceView source, {
    String? passwordOverride,
    bool clearPassword = false,
  }) async {
    throw UnsupportedError('测试替身不创建真实网络媒体源网关');
  }
}

/// 空本地流网桥测试替身。
final class FakeLocalStreamBridge implements LocalStreamBridgePort {
  final List<String> unregisteredTokens = <String>[];

  @override
  int? get port => null;

  @override
  int get activeSessionCount => 0;

  @override
  Future<({String token, Uri url})> registerSession({
    required ByteRangeReadableGateway gateway,
    required String relativePath,
    required String fileName,
    int? knownLength,
    bool ownsGateway = false,
    MediaSourceKind sourceKind = MediaSourceKind.webdav,
  }) async => (token: 'tok', url: Uri.parse('http://127.0.0.1/tok'));

  @override
  Future<bool> prewarmSessionMetadata(
    String token, {
    int headBytes = 1024 * 1024,
    int tailBytes = 512 * 1024,
  }) async => true;

  @override
  Future<void> unregisterSession(String token) async {
    unregisteredTokens.add(token);
  }

  @override
  Future<VirtualAlbumRegistration> registerCueAlbumSession({
    required ByteRangeReadableGateway gateway,
    required String normalizedCueText,
    required List<VirtualAlbumAudioEntry> audioEntries,
    bool ownsGateway = true,
    MediaSourceKind sourceKind = MediaSourceKind.webdav,
  }) async => throw UnimplementedError();

  @override
  Future<VirtualAlbumRegistration> registerPlaylistM3u8Session({
    required ByteRangeReadableGateway gateway,
    required List<VirtualAlbumAudioEntry> audioEntries,
    bool ownsGateway = true,
    MediaSourceKind sourceKind = MediaSourceKind.webdav,
  }) async => throw UnimplementedError();

  @override
  Future<void> unregisterAlbumSession(String albumToken) async {}

  @override
  Future<List<String>> resolveExistingCachedSubtitles({
    required String workId,
    required List<String> subtitleRelativePaths,
    String? sourceId,
    Map<String, String>? validatorsByPath,
  }) async => const <String>[];

  @override
  Future<List<String>> materializeRemoteSubtitles({
    required ByteRangeReadableGateway gateway,
    required String workId,
    required List<String> subtitleRelativePaths,
    String? sourceId,
    Map<String, String>? validatorsByPath,
  }) async => const <String>[];

  @override
  Future<List<MaterializedSubtitleRecord>> materializeRemoteSubtitleRecords({
    required ByteRangeReadableGateway gateway,
    required String workId,
    required List<String> subtitleRelativePaths,
    String? sourceId,
    Map<String, String>? validatorsByPath,
  }) async => const <MaterializedSubtitleRecord>[];

  @override
  String? describeLastError({String? token, String? relativePath}) => null;

  @override
  SourceAccessProblemKind? lastErrorKind({
    String? token,
    String? relativePath,
  }) => null;

  @override
  Future<int> pruneIdleSessions({Duration? maxIdle, DateTime? now}) async => 0;

  @override
  Future<void> close() async {}
}

/// 可配置接力成功与组件探测结果的桌面外置播放器网关替身。
final class FakeDesktopRelayGateway implements DesktopRelayGateway {
  int launchCount = 0;
  int? lastStartSeconds;
  FoobarComponentStatusSnapshot probeResult =
      const FoobarComponentStatusSnapshot(
        state: FoobarComponentState.connected,
        port: 8880,
      );
  PlaybackProgressCallback? lastProgressCallback;

  @override
  Future<List<RelayTargetDescriptor>> listVideoTargets() async =>
      const <RelayTargetDescriptor>[];

  @override
  Future<LaunchPlaybackResult> launchVideo({
    required WorkRecord work,
    required EpisodeSummaryView episode,
    required MediaVariantRecord variant,
    MediaSourceView? source,
    String? targetId,
    String? preferredKindKey,
    int startSeconds = 0,
    int? mainEpisodeCount,
    PlaybackProgressCallback? onProgressUpdate,
  }) async {
    launchCount++;
    lastStartSeconds = startSeconds;
    lastProgressCallback = onProgressUpdate;
    return const LaunchPlaybackResult(launched: true, message: '已调起外部播放器接力播放');
  }

  @override
  Future<LaunchPlaybackResult> launchAudio({
    required WorkRecord work,
    required EpisodeSummaryView episode,
    required MediaVariantRecord variant,
    MediaSourceView? source,
    String? targetId,
    int startSeconds = 0,
    double? exactStartSeconds,
    PlaybackProgressCallback? onProgressUpdate,
  }) async => const LaunchPlaybackResult(launched: true, message: 'ok');

  @override
  Future<LaunchPlaybackResult> launchAudioAlbum(
    ExternalAudioAlbumRelayRequest request, {
    ExternalAudioProgressCallback? onTrackProgress,
  }) async => const LaunchPlaybackResult(launched: true, message: 'ok');

  @override
  Future<FoobarComponentStatusSnapshot> probeAudioPlayerStatus({
    int beefwebPort = FoobarBeefwebConfig.defaultPort,
  }) async => probeResult;

  @override
  Future<void> stopActiveExternalAudioSession({
    int beefwebPort = FoobarBeefwebConfig.defaultPort,
  }) async {}
}

/// 内存态外置播放器配置存储替身。
final class InMemoryExternalPlayerStore implements DesktopExternalPlayerStore {
  final Map<String, ExternalPlayerConfig> _items =
      <String, ExternalPlayerConfig>{};

  @override
  Future<List<ExternalPlayerConfig>> getExternalPlayers() async =>
      _items.values.toList();

  @override
  Future<void> upsertExternalPlayer(ExternalPlayerConfig config) async {
    _items[config.id] = config;
  }

  @override
  Future<void> deleteExternalPlayer(String id) async {
    _items.remove(id);
  }
}

/// 纯内存无原生库的客户端测试替身，便于验证选项下发与事件监听。
final class FakeLibMpvClient implements LibMpvClient, LibMpvUnobservable {
  final StreamController<MpvClientEvent> _events =
      StreamController<MpvClientEvent>.broadcast();

  final Map<String, String> options = <String, String>{};
  final Map<String, Object?> properties = <String, Object?>{};
  final List<List<String>> commands = <List<String>>[];
  final Set<int> observedProperties = <int>{};
  List<MpvTrackInfo> trackList = const <MpvTrackInfo>[];
  List<PlaybackChapter> chapterList = const <PlaybackChapter>[];
  List<MpvAudioDevice> audioDevices = const <MpvAudioDevice>[];

  bool _initialized = false;
  bool _disposed = false;

  @override
  int get handleAddress => 0;

  @override
  bool get isInitialized => _initialized;

  @override
  bool get isDisposed => _disposed;

  @override
  String errorString(int code) => 'err($code)';

  @override
  int setOptionString(String name, String value) {
    options[name] = value;
    return 0;
  }

  @override
  int initialize() {
    _initialized = true;
    return 0;
  }

  @override
  int setPropertyString(String name, String value) {
    properties[name] = value;
    return 0;
  }

  @override
  int setPropertyFlag(String name, bool value) {
    properties[name] = value;
    return 0;
  }

  @override
  int setPropertyInt64(String name, int value) {
    properties[name] = value;
    return 0;
  }

  @override
  int setPropertyDouble(String name, double value) {
    properties[name] = value;
    return 0;
  }

  @override
  String? getPropertyString(String name) => properties[name] as String?;

  @override
  bool? getPropertyFlag(String name) => properties[name] as bool?;

  @override
  int? getPropertyInt64(String name) => properties[name] as int?;

  @override
  double? getPropertyDouble(String name) => properties[name] as double?;

  @override
  List<MpvTrackInfo> readTrackList() => trackList;

  @override
  List<PlaybackChapter> readChapterList({double? totalDurationSeconds}) =>
      chapterList;

  @override
  List<MpvAudioDevice> readAudioDeviceList() => audioDevices;

  @override
  List<MpvSeekableRange> readDemuxerSeekableRanges() =>
      const <MpvSeekableRange>[];

  @override
  int observeProperty(int replyUserdata, String name, int format) {
    observedProperties.add(replyUserdata);
    return 0;
  }

  @override
  int unobserveProperty(int registeredReplyUserdata) {
    observedProperties.remove(registeredReplyUserdata);
    return 0;
  }

  @override
  int requestLogMessages(String minLevel) => 0;

  @override
  int command(List<String> args) {
    commands.add(args);
    return 0;
  }

  @override
  int commandAsync(int replyUserdata, List<String> args) {
    commands.add(args);
    return 0;
  }

  @override
  Stream<MpvClientEvent> get events => _events.stream;

  void emitEvent(MpvClientEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _events.close();
  }
}

/// 完整装配内存数据库、事件总线与可观察替身端口的包级测试台架。
final class VideoTestHarness {
  VideoTestHarness._({
    required this.tempDir,
    required this.storageRoot,
    required this.databases,
    required this.scopedPrefs,
    required this.domainEventBus,
    required this.hostWindow,
    required this.filePicker,
    required this.urlOpener,
    required this.navigator,
    required this.streamBridge,
    required this.gatewayFactory,
    required this.diagnosticLog,
    required this.desktopRelay,
    required this.externalPlayerStore,
    required this.preferencesStore,
    required this.shaderService,
    required this.pipStore,
    required this.engine,
    required this.audiophileCoordinator,
    required this.platform,
  });

  final Directory tempDir;
  final TempStorageRootPort storageRoot;
  final KonataDatabaseBundle databases;
  final ScopedPrefsStore scopedPrefs;
  final InMemoryDomainEventBus domainEventBus;
  final FakePlaybackHostWindowPort hostWindow;
  final FakeVideoFilePicker filePicker;
  final FakeUrlOpener urlOpener;
  final FakeVideoNavigator navigator;
  final FakeLocalStreamBridge streamBridge;
  final FakeGatewayFactory gatewayFactory;
  final FakeDiagnosticLogPort diagnosticLog;
  final FakeDesktopRelayGateway desktopRelay;
  final InMemoryExternalPlayerStore externalPlayerStore;
  final VideoPlaybackPreferencesStore preferencesStore;
  final ShaderDiscoveryService shaderService;
  final ScopedPrefsPipRecoveryStore pipStore;
  final UnifiedPlaybackEngine engine;
  final AudiophileSafetyCoordinator audiophileCoordinator;
  final KonataPlatform platform;
  int currentClockMs = 1700000000000;

  static Future<VideoTestHarness> create({
    KonataPlatform platform = KonataPlatform.windows,
  }) async {
    final tempDir = Directory.systemTemp.createTempSync('konata_video_test_');
    final storageRoot = TempStorageRootPort(tempDir);
    final databases = KonataDatabaseBundle.openInMemory();
    final domainEventBus = InMemoryDomainEventBus();
    final scopedPrefs = ScopedPrefsStore(databases.userState);
    final hostWindow = FakePlaybackHostWindowPort();
    final filePicker = FakeVideoFilePicker();
    final urlOpener = FakeUrlOpener();
    final navigator = FakeVideoNavigator();
    final streamBridge = FakeLocalStreamBridge();
    final gatewayFactory = FakeGatewayFactory();
    final diagnosticLog = FakeDiagnosticLogPort();
    final desktopRelay = FakeDesktopRelayGateway();
    final externalPlayerStore = InMemoryExternalPlayerStore();
    late final VideoTestHarness harness;
    final preferencesStore = VideoPlaybackPreferencesStore(
      scopedPrefs,
      eventBus: domainEventBus,
      sourceDeviceId: 'test-device',
      nowMs: () => harness.currentClockMs,
    );
    final shaderService = ShaderDiscoveryService(
      storageRoot: storageRoot,
      preferencesStore: preferencesStore,
      logStore: diagnosticLog,
    );
    final pipStore = ScopedPrefsPipRecoveryStore(scopedPrefs);
    final engine = UnifiedPlaybackEngine();
    final audiophile = AudiophileSafetyCoordinator(
      engine: engine,
      logStore: diagnosticLog,
      isWindowsOverride: platform == KonataPlatform.windows,
      isAndroidOverride: platform != KonataPlatform.windows,
    );

    harness = VideoTestHarness._(
      tempDir: tempDir,
      storageRoot: storageRoot,
      databases: databases,
      scopedPrefs: scopedPrefs,
      domainEventBus: domainEventBus,
      hostWindow: hostWindow,
      filePicker: filePicker,
      urlOpener: urlOpener,
      navigator: navigator,
      streamBridge: streamBridge,
      gatewayFactory: gatewayFactory,
      diagnosticLog: diagnosticLog,
      desktopRelay: desktopRelay,
      externalPlayerStore: externalPlayerStore,
      preferencesStore: preferencesStore,
      shaderService: shaderService,
      pipStore: pipStore,
      engine: engine,
      audiophileCoordinator: audiophile,
      platform: platform,
    );
    return harness;
  }

  /// 构造内置视频控制器测试实例。
  VideoPlaybackController createController({
    LibMpvClient Function()? libMpvClientFactory,
    bool enablePeriodicTimers = true,
  }) {
    return VideoPlaybackController(
      env: VideoPlaybackEnvironment(
        databases: databases,
        storageRoot: storageRoot,
        domainEventBus: domainEventBus,
        hostWindow: hostWindow,
        filePicker: filePicker,
        streamBridge: streamBridge,
        preferencesStore: preferencesStore,
        shaderDiscoveryService: shaderService,
        pipRecoveryStore: pipStore,
        playbackEngine: engine,
        audiophileCoordinator: audiophileCoordinator,
        platform: platform,
        navigator: navigator,
        gatewayFactory: gatewayFactory,
        desktopRelayGateway: desktopRelay,
        diagnosticLog: diagnosticLog,
        libMpvClientFactory: libMpvClientFactory,
        sourceDeviceId: 'test-device',
        nowMs: () => currentClockMs,
        enablePeriodicTimers: enablePeriodicTimers,
      ),
    );
  }

  /// 构造业务包外层依赖集合用于组件测试注入。
  FeaturePlayerVideoDependencies buildDependencies({
    List<PlayerSidePanelContribution> playerSidePanels =
        const <PlayerSidePanelContribution>[],
    Future<String?> Function({String? dialogTitle})? pickExecutableFile,
    Future<List<ShaderImportSource>> Function()? pickShaderFiles,
    ({int port, bool skipGuide}) Function()? readAudioRelayPreferences,
    void Function({int? port, bool? skipGuide})? writeAudioRelayPreferences,
  }) {
    return FeaturePlayerVideoDependencies(
      databases: databases,
      storageRoot: storageRoot,
      diagnosticLog: diagnosticLog,
      scopedPrefs: scopedPrefs,
      domainEventBus: domainEventBus,
      navigator: navigator,
      filePicker: filePicker,
      urlOpener: urlOpener,
      gatewayFactory: gatewayFactory,
      streamBridge: streamBridge,
      platform: platform,
      hostWindow: hostWindow,
      playbackEngine: engine,
      audiophileCoordinator: audiophileCoordinator,
      pipRecoveryStore: pipStore,
      desktopRelayGateway: desktopRelay,
      externalPlayerStore: externalPlayerStore,
      readAudioRelayPreferences: readAudioRelayPreferences,
      writeAudioRelayPreferences: writeAudioRelayPreferences,
      playerSidePanels: playerSidePanels,
      pickExecutableFile: pickExecutableFile,
      pickShaderFiles: pickShaderFiles,
      sourceDeviceId: 'test-device',
    );
  }

  /// 向内存媒体库写入一部含两话正片的标准测试作品与物理版本数据。
  Future<
    ({
      WorkRecord work,
      EpisodeRecord ep1,
      EpisodeRecord ep2,
      MediaVariantRecord v1,
      MediaVariantRecord v2,
    })
  >
  seedSampleAnime({
    String workId = 'work_sample',
    String? videoCodec,
    String? bitDepth,
  }) async {
    const sourceId = SourceId.trusted('src_local');
    databases.library.mediaSources.upsert(
      MediaSourceRecord(
        id: sourceId,
        kind: MediaSourceKind.local,
        label: '本地测试源',
        location: tempDir.path,
      ),
    );

    final work = WorkRecord(
      id: WorkId.trusted(workId),
      title: '测试动画作品',
      originalTitle: 'Test Anime',
      tmdbMediaType: TmdbMediaType.tv,
      year: 2024,
    );
    databases.library.works.upsert(work);

    final ep1 = EpisodeRecord(
      id: EpisodeId.trusted('${workId}_ep1'),
      workId: work.id,
      seasonNumber: 1,
      episodeNumber: 1,
      category: EpisodeCategory.main,
      title: '第一话 启程',
    );
    final ep2 = EpisodeRecord(
      id: EpisodeId.trusted('${workId}_ep2'),
      workId: work.id,
      seasonNumber: 1,
      episodeNumber: 2,
      category: EpisodeCategory.main,
      title: '第二话 邂逅',
    );
    databases.library.episodes.upsert(ep1);
    databases.library.episodes.upsert(ep2);

    final v1 = MediaVariantRecord(
      id: VariantId.trusted('${workId}_var1'),
      workId: work.id,
      episodeId: ep1.id,
      sourceId: sourceId,
      relativePath: '01.mkv',
      fileName: '[TestSub] 01.mkv',
      fileSize: 512 * 1024 * 1024,
      releaseGroup: 'TestSub',
      resolution: '1080p',
      videoCodec: videoCodec,
      bitDepth: bitDepth,
    );
    final v2 = MediaVariantRecord(
      id: VariantId.trusted('${workId}_var2'),
      workId: work.id,
      episodeId: ep2.id,
      sourceId: sourceId,
      relativePath: '02.mkv',
      fileName: '[TestSub] 02.mkv',
      fileSize: 520 * 1024 * 1024,
      releaseGroup: 'TestSub',
      resolution: '1080p',
      videoCodec: videoCodec,
      bitDepth: bitDepth,
    );
    databases.library.mediaVariants.upsert(v1);
    databases.library.mediaVariants.upsert(v2);

    return (work: work, ep1: ep1, ep2: ep2, v1: v1, v2: v2);
  }

  /// 关闭数据库并清理临时目录资源。
  Future<void> dispose() async {
    shaderService.dispose();
    audiophileCoordinator.dispose();
    await domainEventBus.dispose();
    await databases.close();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  }
}

/// 使用无边框纯基础壳层与主题容器包裹测试目标组件。
Widget wrapVideoTestApp({
  required Widget child,
  FeaturePlayerVideoDependencies? dependencies,
  bool dark = true,
}) {
  final theme = dark ? KonataTheme.darkTheme() : KonataTheme.lightTheme();
  final palette = dark ? KonataPalette.dark : KonataPalette.light;
  final toastCtrl = KonataToastController();

  Widget tree = KonataToastScope(
    controller: toastCtrl,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: Material(
        type: MaterialType.transparency,
        child: DefaultTextStyle(
          style: TextStyle(
            fontFamily: KonataTheme.uiFontFamily,
            color: palette.textPrimary,
            fontSize: KonataTheme.fontSizeBody,
            decoration: TextDecoration.none,
          ),
          child: Stack(
            children: [
              Positioned.fill(child: child),
              KonataToastViewport(controller: toastCtrl),
            ],
          ),
        ),
      ),
    ),
  );

  if (dependencies != null) {
    tree = ProviderScope(
      overrides: [
        featurePlayerVideoDependenciesProvider.overrideWithValue(dependencies),
      ],
      child: tree,
    );
  }
  return tree;
}
