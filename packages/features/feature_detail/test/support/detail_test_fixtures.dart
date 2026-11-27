import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:engine_playback/engine_playback.dart';
import 'package:engine_scraping/engine_scraping.dart';
import 'package:engine_sources/engine_sources.dart';
import 'package:feature_detail/feature_detail.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';
import 'package:konata_storage/konata_storage.dart';
import 'package:path/path.dart' as p;

/// 测试专用微型透明 1x1 PNG 图片二进制（可用于解码、图片桩与缓存验证）。
final Uint8List kMinimalValidPngBytes = Uint8List.fromList(<int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0A,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0D,
  0x0A,
  0x2D,
  0xB4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
]);

/// 记录全部路由调用的跨包导航端口测试替身。
final class FakeAppNavigator implements AppNavigator {
  /// 已触发的详情页切换记录。
  final List<({WorkId workId, String? initialTabId})> workDetailCalls =
      <({WorkId workId, String? initialTabId})>[];

  /// 已触发的视频播放器跳转记录。
  final List<({WorkId workId, EpisodeId? episodeId, VariantId? variantId})>
  videoPlayerCalls =
      <({WorkId workId, EpisodeId? episodeId, VariantId? variantId})>[];

  /// 已触发的音频播放器跳转记录。
  final List<({WorkId workId, VariantId? variantId})> audioPlayerCalls =
      <({WorkId workId, VariantId? variantId})>[];

  /// 返回上一页调用次数。
  int popCount = 0;

  @override
  Future<void> switchNavSection(String sectionId) async {}

  @override
  Future<void> openWorkDetail(WorkId workId, {String? initialTabId}) async {
    workDetailCalls.add((workId: workId, initialTabId: initialTabId));
  }

  @override
  Future<void> openVideoPlayer({
    required WorkId workId,
    EpisodeId? episodeId,
    VariantId? variantId,
  }) async {
    videoPlayerCalls.add((
      workId: workId,
      episodeId: episodeId,
      variantId: variantId,
    ));
  }

  @override
  Future<void> openAudioPlayer({
    required WorkId workId,
    VariantId? variantId,
    int? initialCueTrackIndex,
    int? initialPositionSeconds,
  }) async {
    audioPlayerCalls.add((workId: workId, variantId: variantId));
  }

  @override
  Future<void> openSettings({String? sectionId}) async {}

  @override
  Future<bool> pop() async {
    popCount++;
    return true;
  }
}

/// 可配置返回路径的测试用系统文件选择器替身。
final class FakeFilePickerPort implements FilePickerPort {
  /// 构造可设定选定文件结果的测试替身。
  FakeFilePickerPort({this.nextImagePath});

  /// 下次调用 `pickImageFile` 返回的路径。
  String? nextImagePath;

  @override
  Future<String?> pickDirectory({String? dialogTitle}) async => null;

  @override
  Future<String?> pickImageFile({String? dialogTitle}) async => nextImagePath;

  @override
  Future<String?> pickSubtitleFile({String? dialogTitle}) async => null;
}

/// 纯内存可读测试艺术图缓存实现。
final class InMemoryArtworkCacheStore implements ArtworkCacheStore {
  final Map<String, ({Uint8List bytes, int quality})> _store =
      <String, ({Uint8List bytes, int quality})>{};

  @override
  Future<Uint8List?> read(
    String key, {
    int minimumQuality = 0,
    String? owner,
    PhotoSubfolder? subfolder,
  }) async {
    final fullKey = '${owner ?? ''}:${subfolder?.dirName ?? ''}:$key';
    final hit = _store[fullKey];
    if (hit == null || hit.quality < minimumQuality) return null;
    return hit.bytes;
  }

  @override
  Future<void> write(
    String key,
    Uint8List bytes, {
    String? owner,
    int quality = 0,
    PhotoSubfolder? subfolder,
  }) async {
    final fullKey = '${owner ?? ''}:${subfolder?.dirName ?? ''}:$key';
    _store[fullKey] = (bytes: Uint8List.fromList(bytes), quality: quality);
  }

  @override
  Future<Uint8List?> readLocalWorkFile({
    required String owner,
    required PhotoSubfolder subfolder,
    required String fileName,
  }) async => null;
}

/// 可编程 HTTP 路由处理函数签名。
typedef HttpTestHandler =
    FutureOr<KonataHttpResponse> Function(String method, Uri uri);

/// 纯 Dart 测试用网络端口替身（拦截 `TMDB` 与 `Bangumi` 请求，绝不触发真实网络）。
final class FakeHttpClientPort implements KonataHttpClientPort {
  /// 创建可控 HTTP 测试客户端。
  FakeHttpClientPort({this.handler});

  KonataNetworkConfig _config = const KonataNetworkConfig(
    credential: 'test-tmdb-key',
  );

  /// 动态路由处理器。
  HttpTestHandler? handler;

  /// 更新动态路由处理器。
  void setHandler(HttpTestHandler? nextHandler) {
    handler = nextHandler;
  }

  @override
  KonataNetworkConfig get config => _config;

  @override
  void updateConfig(KonataNetworkConfig next) {
    _config = next;
  }

  @override
  Future<KonataHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    RequestPriority priority = RequestPriority.background,
    String? dedupeKey,
    String? bucketKey,
  }) => sendWithFallback(
    method: 'GET',
    primaryUri: uri,
    headers: headers,
    priority: priority,
    dedupeKey: dedupeKey,
    bucketKey: bucketKey,
  );

  @override
  Future<KonataHttpResponse> getWithFallback(
    Uri primaryUri, {
    Uri? backupUri,
    Map<String, String> headers = const <String, String>{},
    RequestPriority priority = RequestPriority.background,
    String? dedupeKey,
    String? bucketKey,
    bool retryOnRateLimit = true,
    Duration? timeoutOverride,
  }) => sendWithFallback(
    method: 'GET',
    primaryUri: primaryUri,
    backupUri: backupUri,
    headers: headers,
    priority: priority,
    dedupeKey: dedupeKey,
    bucketKey: bucketKey,
    retryOnRateLimit: retryOnRateLimit,
    timeoutOverride: timeoutOverride,
  );

  @override
  Future<KonataHttpResponse> post(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    Object? body,
    RequestPriority priority = RequestPriority.background,
    String? dedupeKey,
    String? bucketKey,
  }) => sendWithFallback(
    method: 'POST',
    primaryUri: uri,
    headers: headers,
    body: body,
    priority: priority,
    dedupeKey: dedupeKey,
    bucketKey: bucketKey,
  );

  @override
  Future<KonataHttpResponse> postWithFallback(
    Uri primaryUri, {
    Uri? backupUri,
    Map<String, String> headers = const <String, String>{},
    Object? body,
    RequestPriority priority = RequestPriority.background,
    String? dedupeKey,
    String? bucketKey,
    bool retryOnRateLimit = true,
    Duration? timeoutOverride,
  }) => sendWithFallback(
    method: 'POST',
    primaryUri: primaryUri,
    backupUri: backupUri,
    headers: headers,
    body: body,
    priority: priority,
    dedupeKey: dedupeKey,
    bucketKey: bucketKey,
    retryOnRateLimit: retryOnRateLimit,
    timeoutOverride: timeoutOverride,
  );

  @override
  Future<KonataHttpResponse> sendWithFallback({
    required String method,
    required Uri primaryUri,
    Uri? backupUri,
    Map<String, String> headers = const <String, String>{},
    Object? body,
    RequestPriority priority = RequestPriority.background,
    String? dedupeKey,
    String? bucketKey,
    bool retryOnRateLimit = true,
    Duration? timeoutOverride,
  }) async {
    final h = handler;
    if (h != null) {
      return await h(method, primaryUri);
    }
    return KonataHttpResponse.text('{}', statusCode: 404);
  }

  @override
  void close() {}
}

/// 支持字节范围读取的内存测试媒体源网关。
final class FakeByteRangeGateway
    implements MediaSourceGateway, ByteRangeReadableGateway {
  /// 创建基于文件名映射字节流的模拟网关。
  FakeByteRangeGateway(this.files);

  /// 相对路径到模拟文件字节内容的映射。
  final Map<String, Uint8List> files;

  @override
  Future<List<RemoteEntry>> listDirectory(String relativePath) async {
    return [
      for (final key in files.keys)
        RemoteEntry(
          name: p.basename(key),
          relativePath: key,
          isDirectory: false,
          size: files[key]!.length,
        ),
    ];
  }

  @override
  Future<String?> readTextFile(
    String relativePath, {
    int maxBytes = 256 * 1024,
  }) async => null;

  @override
  Future<String?> testConnection() async => null;

  @override
  Future<int?> probeFileLength(String relativePath) async =>
      files[relativePath]?.length;

  @override
  Future<Stream<List<int>>> openByteRange(
    String relativePath, {
    required int start,
    int? endInclusive,
  }) async {
    final data = files[relativePath] ?? Uint8List(0);
    if (start >= data.length) {
      return const Stream<List<int>>.empty();
    }
    final end = endInclusive == null
        ? data.length
        : (endInclusive + 1).clamp(start, data.length);
    return Stream<List<int>>.value(data.sublist(start, end));
  }

  @override
  Future<void> close() async {}
}

/// 纯 Dart 测试用媒体源网关工厂。
final class FakeGatewayFactory implements MediaSourceGatewayFactoryPort {
  /// 创建固定返回测试网关的工厂。
  FakeGatewayFactory([MediaSourceGateway? gateway])
    : _gateway = gateway ?? FakeByteRangeGateway(const <String, Uint8List>{});

  final MediaSourceGateway _gateway;

  @override
  Future<MediaSourceGateway> create(
    MediaSourceView source, {
    String? passwordOverride,
    bool clearPassword = false,
  }) async => _gateway;
}

/// 纯 Dart 测试用流式网桥端口（记录注册/注销会话）。
final class FakeStreamBridgePort implements LocalStreamBridgePort {
  final Set<String> activeTokens = <String>{};
  int _seq = 0;

  @override
  int? get port => 49188;

  @override
  int get activeSessionCount => activeTokens.length;

  @override
  Future<({String token, Uri url})> registerSession({
    required ByteRangeReadableGateway gateway,
    required String relativePath,
    required String fileName,
    int? knownLength,
    bool ownsGateway = false,
    MediaSourceKind sourceKind = MediaSourceKind.webdav,
  }) async {
    final token = 'detail_tok_${++_seq}';
    activeTokens.add(token);
    return (
      token: token,
      url: Uri.parse(
        'http://127.0.0.1:49188/stream/$token/${Uri.encodeComponent(fileName)}',
      ),
    );
  }

  @override
  Future<bool> prewarmSessionMetadata(
    String token, {
    int headBytes = 1024 * 1024,
    int tailBytes = 512 * 1024,
  }) async => true;

  @override
  Future<void> unregisterSession(String token) async {
    activeTokens.remove(token);
  }

  @override
  Future<VirtualAlbumRegistration> registerCueAlbumSession({
    required ByteRangeReadableGateway gateway,
    required String normalizedCueText,
    required List<VirtualAlbumAudioEntry> audioEntries,
    bool ownsGateway = true,
    MediaSourceKind sourceKind = MediaSourceKind.webdav,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<VirtualAlbumRegistration> registerPlaylistM3u8Session({
    required ByteRangeReadableGateway gateway,
    required List<VirtualAlbumAudioEntry> audioEntries,
    bool ownsGateway = true,
    MediaSourceKind sourceKind = MediaSourceKind.webdav,
  }) {
    throw UnimplementedError();
  }

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
  Future<void> close() async {
    activeTokens.clear();
  }
}

/// 并发追踪器与离屏软渲染假 `libmpv` 客户端（用于精准验证全局单并发串行抽帧）。
final class FakeSoftwareFrameMpvClient
    implements LibMpvClient, LibMpvSoftwareFrameSource {
  /// 创建离屏软件抽帧客户端替身。
  FakeSoftwareFrameMpvClient({
    required this.onEnterSession,
    required this.onExitSession,
    this.seekDelay = const Duration(milliseconds: 20),
  });

  /// 会话进入回调（记录当前并发数）。
  final void Function() onEnterSession;

  /// 会话结束释放回调。
  final void Function() onExitSession;

  /// 模拟单次寻帧延时（用于构造并发竞争窗口）。
  final Duration seekDelay;

  final StreamController<MpvClientEvent> _events =
      StreamController<MpvClientEvent>.broadcast();
  final StreamController<void> _renderUpdates =
      StreamController<void>.broadcast();
  final List<List<String>> commands = <List<String>>[];
  final List<String> loadedTargets = <String>[];
  bool _entered = false;
  bool _frameReady = false;

  @override
  bool isInitialized = false;

  @override
  bool isDisposed = false;

  @override
  int get handleAddress => 7777;

  @override
  Stream<MpvClientEvent> get events => _events.stream;

  @override
  Stream<void> get softwareRenderUpdates => _renderUpdates.stream;

  @override
  String errorString(int code) => 'err($code)';

  @override
  int setOptionString(String name, String value) => MpvError.success;

  @override
  int initialize() {
    isInitialized = true;
    _entered = true;
    onEnterSession();
    return MpvError.success;
  }

  @override
  int setPropertyString(String name, String value) => MpvError.success;

  @override
  int setPropertyFlag(String name, bool value) => MpvError.success;

  @override
  int setPropertyInt64(String name, int value) => MpvError.success;

  @override
  int setPropertyDouble(String name, double value) => MpvError.success;

  @override
  String? getPropertyString(String name) => null;

  @override
  bool? getPropertyFlag(String name) => false;

  @override
  int? getPropertyInt64(String name) => 0;

  @override
  double? getPropertyDouble(String name) {
    if (name == 'duration') return 1420.0;
    if (name == 'video-params/aspect') return 16 / 9;
    return null;
  }

  @override
  List<MpvTrackInfo> readTrackList() => const <MpvTrackInfo>[];

  @override
  List<PlaybackChapter> readChapterList({double? totalDurationSeconds}) =>
      const <PlaybackChapter>[];

  @override
  List<MpvAudioDevice> readAudioDeviceList() => const <MpvAudioDevice>[];

  @override
  List<MpvSeekableRange> readDemuxerSeekableRanges() =>
      const <MpvSeekableRange>[];

  @override
  int observeProperty(int replyUserdata, String name, int format) =>
      MpvError.success;

  int unobserveProperty(int registeredReplyUserdata) => MpvError.success;

  @override
  int requestLogMessages(String minLevel) => MpvError.success;

  @override
  int command(List<String> args) {
    commands.add(List<String>.from(args));
    if (args.isNotEmpty && args.first == 'loadfile' && args.length >= 2) {
      loadedTargets.add(args[1]);
      scheduleMicrotask(() {
        if (!_events.isClosed) {
          _events.add(const MpvFileLoadedEvent());
        }
      });
    } else if (args.isNotEmpty && args.first == 'seek') {
      Future<void>.delayed(seekDelay, () {
        if (_events.isClosed || isDisposed) return;
        _frameReady = true;
        _events.add(const MpvPlaybackRestartEvent());
        if (!_renderUpdates.isClosed) {
          _renderUpdates.add(null);
        }
      });
    }
    return MpvError.success;
  }

  @override
  int commandAsync(int replyUserdata, List<String> args) => command(args);

  @override
  bool initSoftwareRenderer({int width = 192, int height = 108}) => true;

  @override
  bool pollSoftwareFrameReady() => _frameReady;

  @override
  Uint8List? renderSoftwareFrameBmp({int width = 192, int height = 108}) {
    final safeW = LibMpvSoftwareFrameSource.alignDimension(width);
    final safeH = LibMpvSoftwareFrameSource.alignDimension(height);
    final rgb0 = Uint8List(safeW * safeH * 4);
    for (var y = 0; y < safeH; y++) {
      for (var x = 0; x < safeW; x++) {
        final offset = (y * safeW + x) * 4;
        rgb0[offset] = (x * 5 + y * 3) % 240;
        rgb0[offset + 1] = (x * 2 + y * 7) % 240;
        rgb0[offset + 2] = (x * 9 + y * 11) % 240;
        rgb0[offset + 3] = 255;
      }
    }
    return encodeRgb0ToBmp(rgb0, safeW, safeH);
  }

  @override
  void releaseSoftwareRenderer() {}

  @override
  Future<void> dispose() async {
    if (!isDisposed) {
      isDisposed = true;
      if (_entered) {
        _entered = false;
        onExitSession();
      }
      await _events.close();
      await _renderUpdates.close();
    }
  }
}

/// 组装一套完整、隔离、零磁盘污染的 `feature_detail` 测试环境上下文。
final class DetailTestHarness {
  DetailTestHarness._({
    required this.tempRoot,
    required this.storageRoot,
    required this.databases,
    required this.repository,
    required this.scopedPrefs,
    required this.photosStorage,
    required this.domainEventBus,
    required this.navigator,
    required this.filePicker,
    required this.httpClient,
    required this.gatewayFactory,
    required this.streamBridge,
    required this.warmupService,
    required this.artworkCache,
    required this.diagnosticLog,
  });

  /// 创建独立临时存储与三库合一内存环境的详情测试夹具，并自动注册清理钩子。
  static Future<DetailTestHarness> create({
    HttpTestHandler? httpHandler,
    MediaSourceGateway? gateway,
  }) async {
    final tempRoot = await Directory.systemTemp.createTemp('konata_detail_t_');
    final storageRoot = PortableStorageRootService(
      overrideRootPath: tempRoot.path,
    );
    final databases = KonataDatabaseBundle.openInMemory();
    final scopedPrefs = ScopedPrefsStore(databases.userState);
    final photosStorage = PhotosStorage(storageRoot: storageRoot);
    final domainEventBus = InMemoryDomainEventBus();
    final navigator = FakeAppNavigator();
    final filePicker = FakeFilePickerPort();
    final httpClient = FakeHttpClientPort(handler: httpHandler);
    final gatewayFactory = FakeGatewayFactory(gateway);
    final streamBridge = FakeStreamBridgePort();
    final diagnosticLog = DiagnosticLogStore();
    final warmupService = WorkDetailWarmupService(
      gatewayFactory: gatewayFactory,
      directoryIndex: SubtitleDirectoryIndex(),
    );
    final artworkCache = InMemoryArtworkCacheStore();
    final repository = StorageScrapeRepository(databases);

    addTearDown(() async {
      warmupService.cancelPending();
      await streamBridge.close();
      httpClient.close();
      await domainEventBus.dispose();
      await databases.close();
      if (tempRoot.existsSync()) {
        try {
          tempRoot.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    return DetailTestHarness._(
      tempRoot: tempRoot,
      storageRoot: storageRoot,
      databases: databases,
      repository: repository,
      scopedPrefs: scopedPrefs,
      photosStorage: photosStorage,
      domainEventBus: domainEventBus,
      navigator: navigator,
      filePicker: filePicker,
      httpClient: httpClient,
      gatewayFactory: gatewayFactory,
      streamBridge: streamBridge,
      warmupService: warmupService,
      artworkCache: artworkCache,
      diagnosticLog: diagnosticLog,
    );
  }

  /// 临时根目录。
  final Directory tempRoot;

  /// 存储根目录端口。
  final PortableStorageRootService storageRoot;

  /// 三库合一内存数据库总管。
  final KonataDatabaseBundle databases;

  /// 详情领域仓储实例。
  final StorageScrapeRepository repository;

  /// 偏好存储器。
  final ScopedPrefsStore scopedPrefs;

  /// 受管 `photos/` 管理器。
  final PhotosStorage photosStorage;

  /// 领域事件总线。
  final DomainEventBus domainEventBus;

  /// 模拟跨包导航器。
  final FakeAppNavigator navigator;

  /// 模拟系统文件选择器。
  final FakeFilePickerPort filePicker;

  /// 模拟网络客户端。
  final FakeHttpClientPort httpClient;

  /// 模拟网关工厂。
  final FakeGatewayFactory gatewayFactory;

  /// 模拟流式网桥。
  final FakeStreamBridgePort streamBridge;

  /// 详情页静默预热服务。
  final WorkDetailWarmupService warmupService;

  /// 内存艺术图缓存。
  final InMemoryArtworkCacheStore artworkCache;

  /// 结构化诊断日志容器。
  final DiagnosticLogStore diagnosticLog;

  static MediaSourceView _toSourceView(MediaSource source) {
    return MediaSourceView(
      id: SourceId.trusted(source.id),
      kind: source.kind,
      label: source.label,
      location: source.location,
      username: source.username,
    );
  }

  /// 构造供 `ProviderScope` 注入的 `FeatureDetailDependencies`。
  FeatureDetailDependencies buildDependencies({
    KonataPlatform platform = KonataPlatform.windows,
    List<DetailTabContribution> detailTabs = const <DetailTabContribution>[],
    List<DetailActionContribution> detailActions =
        const <DetailActionContribution>[],
    LibMpvClient Function()? libMpvClientFactory,
    DesktopRelayGateway? desktopRelayGateway,
    Future<void> Function()? prepareExternalVideo,
    bool autoStartWarmupAndBackfill = false,
  }) {
    return FeatureDetailDependencies(
      databases: databases,
      storageRoot: storageRoot,
      diagnosticLog: diagnosticLog,
      scopedPrefs: scopedPrefs,
      domainEventBus: domainEventBus,
      navigator: navigator,
      filePicker: filePicker,
      urlOpener: const NoopUrlOpenerPort(),
      httpClient: httpClient,
      gatewayFactory: gatewayFactory,
      streamBridge: streamBridge,
      warmupService: warmupService,
      photosStorage: photosStorage,
      artworkCache: artworkCache,
      platform: platform,
      detailTabs: detailTabs,
      detailActions: detailActions,
      libMpvClientFactory: libMpvClientFactory,
      desktopRelayGateway: desktopRelayGateway,
      prepareExternalVideo: prepareExternalVideo,
      autoStartWarmupAndBackfill: autoStartWarmupAndBackfill,
    );
  }

  /// 直接构造独立可测的 [WorkDetailController]。
  WorkDetailController createController(
    WorkId workId, {
    KonataPlatform platform = KonataPlatform.windows,
    List<DetailTabContribution> detailTabs = const <DetailTabContribution>[],
    List<DetailActionContribution> detailActions =
        const <DetailActionContribution>[],
    MainEpisodeFrameExtractor? extractor,
    bool autoStartWarmupAndBackfill = false,
  }) {
    final tmdb = TmdbService(
      httpClient: httpClient,
      artworkCache: artworkCache,
    );
    final bgm = BangumiService(httpClient: httpClient);
    final fanartCache = FanartArtworkCache();
    final fanart = FanartService(
      httpClient: httpClient,
      circuitBreaker: FanartCircuitBreaker(),
      artworkCache: fanartCache,
    );
    final clearLogo = ClearLogoResolver(
      tmdbService: tmdb,
      fanartService: fanart,
      networkConfig: httpClient.config,
    );
    final pipeline = ScrapePipeline(
      repository: repository,
      tmdbService: tmdb,
      bangumiService: bgm,
      fanartService: fanart,
      clearLogoResolver: clearLogo,
      gatewayBuilder: (src) => gatewayFactory.create(_toSourceView(src)),
      photosStorage: PhotosStorageArtworkPortAdapter(photosStorage),
      diagnosticLog: diagnosticLog,
      eventBus: domainEventBus,
    );
    final effectiveExtractor =
        extractor ??
        MainEpisodeFrameExtractor(
          streamBridge: streamBridge,
          gatewayFactory: gatewayFactory,
          logStore: diagnosticLog,
        );
    final backfill = MainEpisodeFrameBackfillService(
      repository: repository,
      photosStorage: photosStorage,
      extractor: effectiveExtractor,
    );
    final artworkOptions = WorkArtworkOptionsService(
      httpClient: httpClient,
      tmdbService: tmdb,
      bangumiService: bgm,
      fanartService: fanart,
    );
    final actionsService = DetailWorkActionsService(
      repository: repository,
      databases: databases,
      photosStorage: photosStorage,
      domainEventBus: domainEventBus,
      tmdbService: tmdb,
      bangumiService: bgm,
      scrapePipeline: pipeline,
    );
    final prefsStore = DetailDisplayPreferencesStore(scopedPrefs);

    final ctrl = WorkDetailController(
      workId: workId,
      databases: databases,
      repository: repository,
      photosStorage: photosStorage,
      domainEventBus: domainEventBus,
      navigator: navigator,
      filePicker: filePicker,
      urlOpener: const NoopUrlOpenerPort(),
      warmupService: warmupService,
      platform: platform,
      detailTabs: detailTabs,
      detailActions: detailActions,
      displayPreferencesStore: prefsStore,
      frameBackfillService: backfill,
      artworkOptionsService: artworkOptions,
      actionsService: actionsService,
      scrapePipeline: pipeline,
      tmdbService: tmdb,
      bangumiService: bgm,
      autoStartWarmupAndBackfill: autoStartWarmupAndBackfill,
    );
    addTearDown(fanartCache.clear);
    addTearDown(ctrl.dispose);
    return ctrl;
  }
}

/// 在仅引入 `konata_design_system` 与 `WidgetsApp` 的纯无框壳下挂载组件测试页。
Widget wrapDetailTestApp({
  required Widget child,
  FeatureDetailDependencies? dependencies,
  bool dark = true,
  double bottomClearance = 16.0,
}) {
  final theme = dark ? KonataTheme.darkTheme() : KonataTheme.lightTheme();
  final palette = dark ? KonataPalette.dark : KonataPalette.light;
  final toastCtrl = KonataToastController();
  Widget tree = KonataToastScope(
    controller: toastCtrl,
    child: KonataBottomClearanceScope(
      bottomClearance: bottomClearance,
      child: Theme(
        data: theme,
        child: DefaultTextStyle(
          style: TextStyle(
            fontFamily: KonataTheme.uiFontFamily,
            color: palette.textPrimary,
            fontSize: KonataTheme.fontSizeBody,
            decoration: TextDecoration.none,
          ),
          child: WidgetsApp(
            color: KonataTheme.cinemaObsidian,
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            supportedLocales: const <Locale>[
              Locale('zh', 'CN'),
              Locale('en', 'US'),
            ],
            pageRouteBuilder:
                <T>(RouteSettings settings, WidgetBuilder builder) =>
                    PageRouteBuilder<T>(
                      settings: settings,
                      pageBuilder: (ctx, _, _) => builder(ctx),
                    ),
            home: child,
          ),
        ),
      ),
    ),
  );
  if (dependencies != null) {
    tree = ProviderScope(
      overrides: [
        featureDetailDependenciesProvider.overrideWithValue(dependencies),
      ],
      child: tree,
    );
  }
  return tree;
}

/// 测试专用可控假 `DetailManagedImageLoader`（任意请求均秒回 2x2 PNG 字节流）。
ManagedImageLoader createStubImageLoader() {
  return (String url, {int? targetWidth, TmdbImageSize? imageSize}) async =>
      kMinimalValidPngBytes;
}
