import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:engine_playback/engine_playback.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

/// 用于测试音频内核行为的可编程受控 `LibMpvClient` 替身。
class FakeLibMpvClient implements LibMpvClient, LibMpvUnobservable {
  /// 构造受控播放内核替身。
  FakeLibMpvClient({
    this.failInitializeCode = 0,
    this.failLoadFile = false,
  });

  final int failInitializeCode;
  final bool failLoadFile;

  final StreamController<MpvClientEvent> _events =
      StreamController<MpvClientEvent>.broadcast();

  final Map<String, Object?> options = <String, Object?>{};
  final Map<String, Object?> properties = <String, Object?>{
    'audio-exclusive': true,
    'current-ao': 'wasapi',
    'audio-device': 'auto',
  };
  final Map<int, String> observedProperties = <int, String>{};
  final List<List<String>> commands = <List<String>>[];
  final List<double> recordedVolumes = <double>[];
  List<MpvAudioDevice> devices = const <MpvAudioDevice>[
    MpvAudioDevice(name: 'auto', description: '默认系统输出'),
    MpvAudioDevice(
      name: 'wasapi/{dac-01}',
      description: 'USB Hi-Res DAC (WASAPI)',
    ),
  ];

  bool _initialized = false;
  bool _disposed = false;

  @override
  int get handleAddress => 1;

  @override
  bool get isInitialized => _initialized;

  @override
  bool get isDisposed => _disposed;

  @override
  Stream<MpvClientEvent> get events => _events.stream;

  @override
  String errorString(int code) => 'err($code)';

  @override
  int setOptionString(String name, String value) {
    options[name] = value;
    return 0;
  }

  @override
  int initialize() {
    if (failInitializeCode < 0) return failInitializeCode;
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
    if (name == 'volume') {
      recordedVolumes.add(value);
    }
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
  List<MpvTrackInfo> readTrackList() => const <MpvTrackInfo>[];

  @override
  List<PlaybackChapter> readChapterList({double? totalDurationSeconds}) =>
      const <PlaybackChapter>[];

  @override
  List<MpvAudioDevice> readAudioDeviceList() => devices;

  @override
  List<MpvSeekableRange> readDemuxerSeekableRanges() =>
      const <MpvSeekableRange>[];

  @override
  int observeProperty(int replyUserdata, String name, int format) {
    observedProperties[replyUserdata] = name;
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
    commands.add(List<String>.from(args));
    if (args.isNotEmpty && args.first == 'loadfile' && failLoadFile) {
      return -1;
    }
    return 0;
  }

  @override
  int commandAsync(int replyUserdata, List<String> args) => command(args);

  /// 主动向测试中的控制器注入模拟原生事件。
  void emitEvent(MpvClientEvent event) {
    if (!_disposed) {
      _events.add(event);
    }
  }

  /// 向订阅中的控制器发送 `time-pos` 属性变更事件。
  void emitTimePos(double seconds) {
    properties['time-pos'] = seconds;
    emitEvent(
      MpvPropertyChangeEvent(
        name: 'time-pos',
        replyUserdata: 10,
        format: MpvFormat.double_,
        doubleValue: seconds,
      ),
    );
  }

  /// 发送总时长属性变更事件。
  void emitDuration(double seconds) {
    properties['duration'] = seconds;
    emitEvent(
      MpvPropertyChangeEvent(
        name: 'duration',
        replyUserdata: 11,
        format: MpvFormat.double_,
        doubleValue: seconds,
      ),
    );
  }

  /// 返回当前 `af` 音频滤镜串。
  String get currentAf => getPropertyString('af') ?? '';

  /// 是否正在监听指定属性名。
  bool isObserving(String name) => observedProperties.containsValue(name);

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _events.close();
  }
}

/// 基于内存文件的测试专用虚拟媒体源只读网关。
class FakeByteRangeGateway
    implements MediaSourceGateway, ByteRangeReadableGateway {
  /// 使用内存文件映射创建虚拟网关。
  FakeByteRangeGateway(this.files);

  final Map<String, Uint8List> files;
  bool closed = false;

  String _norm(String raw) {
    final clean = raw.replaceAll('\\', '/').trim();
    return clean.startsWith('/') ? clean.substring(1) : clean;
  }

  @override
  Future<List<RemoteEntry>> listDirectory(String relativePath) async {
    final prefix = _norm(relativePath);
    final result = <RemoteEntry>[];
    for (final entry in files.entries) {
      final path = _norm(entry.key);
      final dir = path.contains('/')
          ? path.substring(0, path.lastIndexOf('/'))
          : '';
      if (dir.toLowerCase() == prefix.toLowerCase()) {
        final name = path.contains('/')
            ? path.substring(path.lastIndexOf('/') + 1)
            : path;
        result.add(
          RemoteEntry(
            name: name,
            relativePath: path,
            isDirectory: false,
            size: entry.value.length,
          ),
        );
      }
    }
    return result;
  }

  @override
  Future<String?> readTextFile(
    String relativePath, {
    int maxBytes = 256 * 1024,
  }) async {
    final data = files[_norm(relativePath)];
    if (data == null) return null;
    return utf8.decode(data);
  }

  @override
  Future<int?> probeFileLength(String relativePath) async =>
      files[_norm(relativePath)]?.length;

  @override
  Future<Stream<List<int>>> openByteRange(
    String relativePath, {
    required int start,
    int? endInclusive,
  }) async {
    final data = files[_norm(relativePath)];
    if (data == null) {
      throw StateError('测试虚拟文件不存在: $relativePath');
    }
    if (start >= data.length) {
      return const Stream<List<int>>.empty();
    }
    final safeEnd = endInclusive != null
        ? math.min(endInclusive + 1, data.length)
        : data.length;
    return Stream<List<int>>.value(data.sublist(start, safeEnd));
  }

  @override
  Future<String?> testConnection() async => null;

  @override
  Future<void> close() async {
    closed = true;
  }
}

/// 内存网关工厂。
class FakeGatewayFactory implements MediaSourceGatewayFactoryPort {
  /// 构造网关工厂。
  FakeGatewayFactory(this.files);

  final Map<String, Uint8List> files;

  @override
  Future<MediaSourceGateway> create(
    MediaSourceView source, {
    String? passwordOverride,
    bool clearPassword = false,
  }) async {
    return FakeByteRangeGateway(files);
  }
}

/// 无需真实 HTTP Socket 的轻量流网桥桩对象。
class FakeStreamBridge implements LocalStreamBridgePort {
  int _counter = 0;
  final Map<String, String> registeredTokens = <String, String>{};
  final Set<String> unregisteredTokens = <String>{};
  String? mockedLastError;

  @override
  int? get port => 18080;

  @override
  int get activeSessionCount => registeredTokens.length;

  @override
  Future<({String token, Uri url})> registerSession({
    required ByteRangeReadableGateway gateway,
    required String relativePath,
    required String fileName,
    int? knownLength,
    bool ownsGateway = false,
    MediaSourceKind sourceKind = MediaSourceKind.webdav,
  }) async {
    final token = 'tok_${++_counter}';
    registeredTokens[token] = relativePath;
    if (ownsGateway) {
      await gateway.close();
    }
    return (
      token: token,
      url: Uri.parse('http://127.0.0.1:18080/stream/$token/$fileName'),
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
    registeredTokens.remove(token);
    unregisteredTokens.add(token);
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
  String? describeLastError({String? token, String? relativePath}) =>
      mockedLastError;

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

/// 记录切歌/清空歌词调用频次的模拟 `LyricDisplayPort`。
class SpyLyricDisplayPort implements LyricDisplayPort {
  final List<LyricTrackQuery> resolvedQueries = <LyricTrackQuery>[];
  final List<List<LyricTrackQuery>> prefetchedBatches =
      <List<LyricTrackQuery>>[];
  int clearCount = 0;

  @override
  Future<void> resolveForTrack(LyricTrackQuery query) async {
    resolvedQueries.add(query);
  }

  @override
  Future<void> prefetchQueue(List<LyricTrackQuery> upcoming) async {
    prefetchedBatches.add(upcoming);
  }

  @override
  void clearActive() {
    clearCount++;
  }
}

/// 记录窗口迷你置顶调用的模拟宿主窗口端口。
class SpyHostWindowPort implements PlaybackHostWindowPort {
  int enterMiniCount = 0;
  int exitMiniCount = 0;
  double? lastMiniWidth;
  double? lastMiniHeight;

  @override
  Future<bool> isFullScreen() async => false;

  @override
  Future<void> setFullScreen(bool enable) async {}

  @override
  Future<void> setAlwaysOnTop(bool enable) async {}

  @override
  Future<void> enterDesktopMiniWindow({
    required double width,
    required double height,
  }) async {
    enterMiniCount++;
    lastMiniWidth = width;
    lastMiniHeight = height;
  }

  @override
  Future<void> exitDesktopMiniWindow() async {
    exitMiniCount++;
  }

  @override
  Future<void> setKeepScreenOn(bool enable) async {}

  @override
  Future<void> setPreferredLandscape(bool landscape) async {}
}

/// 快速创建测试用作品记录与音轨变体辅助工厂。
WorkRecord makeTestWork({String id = 'work_cd_1', String title = '孤独摇滚原声集'}) {
  return WorkRecord(id: WorkId(id), title: title);
}

MediaSourceView makeTestSource({
  String id = 'src_nas',
  MediaSourceKind kind = MediaSourceKind.webdav,
}) {
  return MediaSourceView(
    id: SourceId(id),
    kind: kind,
    label: '测试媒体库',
    location: 'https://nas.local/music',
  );
}

MediaVariantRecord makeTestCdVariant({
  required String id,
  required String relativePath,
  String workId = 'work_cd_1',
  String sourceId = 'src_nas',
  int fileSize = 4096,
}) {
  final fileName = relativePath.contains('/')
      ? relativePath.substring(relativePath.lastIndexOf('/') + 1)
      : relativePath;
  return MediaVariantRecord(
    id: VariantId(id),
    workId: WorkId(workId),
    sourceId: SourceId(sourceId),
    relativePath: relativePath,
    fileName: fileName,
    fileSize: fileSize,
    assetKind: AssetKind.cdAlbum,
  );
}
