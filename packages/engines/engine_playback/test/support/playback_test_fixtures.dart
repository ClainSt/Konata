import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:engine_playback/engine_playback.dart';
import 'package:konata_contracts/konata_contracts.dart';

/// 播放引擎纯 Dart 测试专用确定性夹具与替身工厂。
abstract final class PlaybackTestFixtures {
  /// 生成满足 TrueType SFNT 规范的微型字体二进制（支持 `.notdef`、`A` 与可选 `中`）。
  static Uint8List generateMinimalDualGlyphTtf({
    String familyName = 'KonataProbeFont',
    bool includeCjk = true,
  }) {
    final tables = <String, Uint8List>{};

    final simpleGlyph = _buildSimpleBoxGlyph();
    final glyfBuilder = BytesBuilder(copy: false);
    final locaOffsets = <int>[];
    for (var i = 0; i < 3; i++) {
      locaOffsets.add(glyfBuilder.length);
      glyfBuilder.add(simpleGlyph);
    }
    locaOffsets.add(glyfBuilder.length);
    tables['glyf'] = glyfBuilder.toBytes();

    final loca = ByteData(locaOffsets.length * 2);
    for (var i = 0; i < locaOffsets.length; i++) {
      loca.setUint16(i * 2, locaOffsets[i] >> 1, Endian.big);
    }
    tables['loca'] = loca.buffer.asUint8List();

    final head = ByteData(54)
      ..setUint32(0, 0x00010000, Endian.big)
      ..setUint32(12, 0x5F0F3CF5, Endian.big)
      ..setUint16(18, 1000, Endian.big)
      ..setInt16(40, 800, Endian.big)
      ..setInt16(42, 800, Endian.big);
    tables['head'] = head.buffer.asUint8List();

    final hhea = ByteData(36)
      ..setUint32(0, 0x00010000, Endian.big)
      ..setInt16(4, 800, Endian.big)
      ..setInt16(6, -200, Endian.big)
      ..setUint16(34, 3, Endian.big);
    tables['hhea'] = hhea.buffer.asUint8List();

    final maxp = ByteData(32)
      ..setUint32(0, 0x00010000, Endian.big)
      ..setUint16(4, 3, Endian.big)
      ..setUint16(6, 4, Endian.big)
      ..setUint16(8, 1, Endian.big);
    tables['maxp'] = maxp.buffer.asUint8List();

    final hmtx = ByteData(12);
    for (var i = 0; i < 3; i++) {
      hmtx.setUint16(i * 4, 600, Endian.big);
    }
    tables['hmtx'] = hmtx.buffer.asUint8List();

    final mappings = <int, int>{0x0041: 1, if (includeCjk) 0x4E2D: 2};
    tables['cmap'] = _buildCmapFormat4(mappings);
    tables['name'] = _buildNameTable(familyName);
    return _assembleSfnt(tables);
  }

  static Uint8List _buildSimpleBoxGlyph() {
    final out = ByteData(32)
      ..setInt16(0, 1, Endian.big)
      ..setInt16(4, 0, Endian.big)
      ..setInt16(6, 500, Endian.big)
      ..setInt16(8, 700, Endian.big)
      ..setUint16(10, 3, Endian.big)
      ..setUint16(12, 0, Endian.big);
    const flagsOffset = 14;
    for (var i = 0; i < 4; i++) {
      out.setUint8(flagsOffset + i, 0x01);
    }
    const xOffset = 18;
    out
      ..setInt16(xOffset, 0, Endian.big)
      ..setInt16(xOffset + 2, 500, Endian.big)
      ..setInt16(xOffset + 4, 0, Endian.big)
      ..setInt16(xOffset + 6, -500, Endian.big);
    const yOffset = 26;
    out
      ..setInt16(yOffset, 0, Endian.big)
      ..setInt16(yOffset + 2, 0, Endian.big)
      ..setInt16(yOffset + 4, 700, Endian.big);
    return out.buffer.asUint8List();
  }

  static Uint8List _buildCmapFormat4(Map<int, int> codePointToGlyph) {
    final sortedCodes = codePointToGlyph.keys.toList()..sort();
    final segCount = sortedCodes.length + 1;
    final startCodes = <int>[...sortedCodes, 0xFFFF];
    final endCodes = <int>[...sortedCodes, 0xFFFF];
    final idDeltas = <int>[
      for (final cp in sortedCodes) (codePointToGlyph[cp]! - cp) & 0xFFFF,
      1,
    ];
    final format4Size = 14 + segCount * 8 + 2;
    final subtable = ByteData(format4Size);
    subtable
      ..setUint16(0, 4, Endian.big)
      ..setUint16(2, format4Size, Endian.big)
      ..setUint16(4, 0, Endian.big)
      ..setUint16(6, segCount * 2, Endian.big);

    var searchRange = 2;
    var entrySelector = 0;
    while (searchRange * 2 <= segCount * 2) {
      searchRange *= 2;
      entrySelector++;
    }
    subtable
      ..setUint16(8, searchRange, Endian.big)
      ..setUint16(10, entrySelector, Endian.big)
      ..setUint16(12, segCount * 2 - searchRange, Endian.big);

    var cursor = 14;
    for (final v in endCodes) {
      subtable.setUint16(cursor, v, Endian.big);
      cursor += 2;
    }
    subtable.setUint16(cursor, 0, Endian.big);
    cursor += 2;
    for (final v in startCodes) {
      subtable.setUint16(cursor, v, Endian.big);
      cursor += 2;
    }
    for (final v in idDeltas) {
      subtable.setUint16(cursor, v, Endian.big);
      cursor += 2;
    }
    for (var i = 0; i < segCount; i++) {
      subtable.setUint16(cursor, 0, Endian.big);
      cursor += 2;
    }

    final cmap = Uint8List(4 + 8 + format4Size);
    final bd = ByteData.sublistView(cmap);
    bd
      ..setUint16(0, 0, Endian.big)
      ..setUint16(2, 1, Endian.big)
      ..setUint16(4, 3, Endian.big)
      ..setUint16(6, 1, Endian.big)
      ..setUint32(8, 12, Endian.big);
    cmap.setRange(12, cmap.length, subtable.buffer.asUint8List());
    return cmap;
  }

  static Uint8List _buildNameTable(String familyName) {
    final nameBytes = _encodeUtf16Be(familyName);
    const headerBytes = 6 + 12;
    final out = Uint8List(headerBytes + nameBytes.length);
    final bd = ByteData.sublistView(out);
    bd
      ..setUint16(0, 0, Endian.big)
      ..setUint16(2, 1, Endian.big)
      ..setUint16(4, headerBytes, Endian.big)
      ..setUint16(6, 3, Endian.big)
      ..setUint16(8, 1, Endian.big)
      ..setUint16(10, 0x0409, Endian.big)
      ..setUint16(12, 1, Endian.big)
      ..setUint16(14, nameBytes.length, Endian.big)
      ..setUint16(16, 0, Endian.big);
    out.setRange(headerBytes, out.length, nameBytes);
    return out;
  }

  static Uint8List _encodeUtf16Be(String text) {
    final units = text.codeUnits;
    final out = Uint8List(units.length * 2);
    final bd = ByteData.sublistView(out);
    for (var i = 0; i < units.length; i++) {
      bd.setUint16(i * 2, units[i], Endian.big);
    }
    return out;
  }

  static Uint8List _assembleSfnt(Map<String, Uint8List> tables) {
    final tags = tables.keys.toList()..sort();
    final numTables = tags.length;
    var maxPow2 = 1;
    var entrySelector = 0;
    while (maxPow2 * 2 <= numTables) {
      maxPow2 *= 2;
      entrySelector++;
    }
    final searchRange = maxPow2 * 16;
    final rangeShift = numTables * 16 - searchRange;

    final headerLen = 12 + numTables * 16;
    var dataOffset = headerLen;
    final records = <({String tag, int offset, int length, Uint8List bytes})>[];
    for (final tag in tags) {
      final raw = tables[tag]!;
      records.add((
        tag: tag,
        offset: dataOffset,
        length: raw.length,
        bytes: raw,
      ));
      dataOffset += (raw.length + 3) & ~3;
    }

    final total = Uint8List(dataOffset);
    final bd = ByteData.sublistView(total);
    bd
      ..setUint32(0, 0x00010000, Endian.big)
      ..setUint16(4, numTables, Endian.big)
      ..setUint16(6, searchRange, Endian.big)
      ..setUint16(8, entrySelector, Endian.big)
      ..setUint16(10, rangeShift, Endian.big);

    var recPos = 12;
    for (final rec in records) {
      total.setRange(recPos, recPos + 4, ascii.encode(rec.tag));
      bd
        ..setUint32(recPos + 4, _sfntChecksum(rec.bytes), Endian.big)
        ..setUint32(recPos + 8, rec.offset, Endian.big)
        ..setUint32(recPos + 12, rec.length, Endian.big);
      recPos += 16;
      total.setRange(rec.offset, rec.offset + rec.length, rec.bytes);
    }
    return total;
  }

  static int _sfntChecksum(Uint8List data) {
    var sum = 0;
    final paddedLen = (data.length + 3) & ~3;
    for (var i = 0; i < paddedLen; i += 4) {
      final b0 = i < data.length ? data[i] : 0;
      final b1 = (i + 1) < data.length ? data[i + 1] : 0;
      final b2 = (i + 2) < data.length ? data[i + 2] : 0;
      final b3 = (i + 3) < data.length ? data[i + 3] : 0;
      final word = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3;
      sum = (sum + word) & 0xFFFFFFFF;
    }
    return sum;
  }

  /// 构造包含可选 Stored / Deflate 条目的最小标准 ZIP 字节包（用于字体压缩包与 Zip-Slip 校验）。
  static Uint8List buildMinimalZip(
    Map<String, Uint8List> entries, {
    bool deflate = false,
  }) {
    final localChunks = BytesBuilder();
    final centralChunks = BytesBuilder();
    var entryCount = 0;

    for (final entry in entries.entries) {
      final nameBytes = utf8.encode(entry.key);
      final raw = entry.value;
      final payload = deflate
          ? Uint8List.fromList(ZLibEncoder(raw: true).convert(raw))
          : raw;
      final method = deflate ? 8 : 0;
      final localOffset = localChunks.length;

      final localHeader = ByteData(30)
        ..setUint32(0, 0x04034b50, Endian.little)
        ..setUint16(4, 20, Endian.little)
        ..setUint16(8, method, Endian.little)
        ..setUint32(18, payload.length, Endian.little)
        ..setUint32(22, raw.length, Endian.little)
        ..setUint16(26, nameBytes.length, Endian.little);

      localChunks
        ..add(localHeader.buffer.asUint8List())
        ..add(nameBytes)
        ..add(payload);

      final cdHeader = ByteData(46)
        ..setUint32(0, 0x02014b50, Endian.little)
        ..setUint16(4, 20, Endian.little)
        ..setUint16(6, 20, Endian.little)
        ..setUint16(10, method, Endian.little)
        ..setUint32(20, payload.length, Endian.little)
        ..setUint32(24, raw.length, Endian.little)
        ..setUint16(28, nameBytes.length, Endian.little)
        ..setUint32(42, localOffset, Endian.little);

      centralChunks
        ..add(cdHeader.buffer.asUint8List())
        ..add(nameBytes);
      entryCount += 1;
    }

    final cdOffset = localChunks.length;
    final cdBytes = centralChunks.takeBytes();
    final eocd = ByteData(22)
      ..setUint32(0, 0x06054b50, Endian.little)
      ..setUint16(8, entryCount, Endian.little)
      ..setUint16(10, entryCount, Endian.little)
      ..setUint32(12, cdBytes.length, Endian.little)
      ..setUint32(16, cdOffset, Endian.little);

    final full = BytesBuilder()
      ..add(localChunks.takeBytes())
      ..add(cdBytes)
      ..add(eocd.buffer.asUint8List());
    return full.takeBytes();
  }
}

/// 纯 Dart 全功能模拟 `LibMpvClient`（追踪选项、属性写入、命令、轨道列表与退订记录）。
class FakeLibMpvClient implements LibMpvClient, LibMpvUnobservable {
  final Map<String, String> options = <String, String>{};
  final Map<String, String> stringProps = <String, String>{};
  final Map<String, bool> boolProps = <String, bool>{'pause': false};
  final Map<String, int> intProps = <String, int>{};
  final Map<String, double> doubleProps = <String, double>{
    'time-pos': 10.0,
    'duration': 1420.0,
    'volume': 100.0,
    'sub-delay': 0.0,
  };
  final List<({String name, Object? value})> propWrites =
      <({String name, Object? value})>[];
  final List<List<String>> commands = <List<String>>[];
  final Set<String> failOptions = <String>{};
  final Set<String> failProps = <String>{};
  final Set<String> failStringAssignments = <String>{};
  final Set<int> observedIds = <int>{};
  final Set<int> unobservedIds = <int>{};
  final List<MpvTrackInfo> tracks = <MpvTrackInfo>[];
  List<PlaybackChapter> chapters = const <PlaybackChapter>[];
  List<MpvAudioDevice> audioDevices = const <MpvAudioDevice>[
    MpvAudioDevice(name: 'auto', description: '自动'),
    MpvAudioDevice(name: 'wasapi/{dac-usb-1}', description: 'USB DAC'),
  ];
  int nextErrorCode = MpvError.optionNotFound;
  int _nextTrackId = 20;
  int _nextPlaylistEntryId = 1;

  final StreamController<MpvClientEvent> _events =
      StreamController<MpvClientEvent>.broadcast();

  @override
  bool isInitialized = false;

  @override
  bool isDisposed = false;

  @override
  int get handleAddress => 9001;

  @override
  Stream<MpvClientEvent> get events => _events.stream;

  void emitEvent(MpvClientEvent event) {
    if (!_events.isClosed) {
      _events.add(event);
    }
  }

  @override
  String errorString(int code) => 'err($code)';

  @override
  int setOptionString(String name, String value) {
    if (failOptions.contains(name)) {
      return nextErrorCode;
    }
    options[name] = value;
    return MpvError.success;
  }

  @override
  int initialize() {
    isInitialized = true;
    return MpvError.success;
  }

  @override
  int setPropertyString(String name, String value) {
    if (failProps.contains(name) ||
        failStringAssignments.contains('$name=$value')) {
      return MpvError.propertyNotFound;
    }
    stringProps[name] = value;
    propWrites.add((name: name, value: value));
    return MpvError.success;
  }

  @override
  int setPropertyFlag(String name, bool value) {
    if (failProps.contains(name)) {
      return MpvError.aoInitFailed;
    }
    boolProps[name] = value;
    propWrites.add((name: name, value: value));
    return MpvError.success;
  }

  @override
  int setPropertyInt64(String name, int value) {
    if (failProps.contains(name)) {
      return MpvError.propertyUnavailable;
    }
    intProps[name] = value;
    propWrites.add((name: name, value: value));
    return MpvError.success;
  }

  @override
  int setPropertyDouble(String name, double value) {
    if (failProps.contains(name)) {
      return MpvError.propertyNotFound;
    }
    doubleProps[name] = value;
    propWrites.add((name: name, value: value));
    return MpvError.success;
  }

  @override
  String? getPropertyString(String name) => stringProps[name];

  @override
  bool? getPropertyFlag(String name) => boolProps[name];

  @override
  int? getPropertyInt64(String name) => intProps[name];

  @override
  double? getPropertyDouble(String name) => doubleProps[name];

  @override
  List<MpvTrackInfo> readTrackList() => List<MpvTrackInfo>.of(tracks);

  @override
  List<PlaybackChapter> readChapterList({double? totalDurationSeconds}) =>
      List<PlaybackChapter>.of(chapters);

  @override
  List<MpvAudioDevice> readAudioDeviceList() => audioDevices;

  @override
  List<MpvSeekableRange> readDemuxerSeekableRanges() => const [];

  @override
  int observeProperty(int replyUserdata, String name, int format) {
    observedIds.add(replyUserdata);
    return MpvError.success;
  }

  @override
  int unobserveProperty(int registeredReplyUserdata) {
    observedIds.remove(registeredReplyUserdata);
    unobservedIds.add(registeredReplyUserdata);
    return MpvError.success;
  }

  @override
  int requestLogMessages(String minLevel) => MpvError.success;

  @override
  int command(List<String> args) {
    commands.add(List<String>.from(args));
    if (args.isNotEmpty &&
        args.first == 'screenshot-to-file' &&
        args.length >= 2) {
      final f = File(args[1]);
      f.parent.createSync(recursive: true);
      f.writeAsBytesSync(<int>[
        0x89,
        0x50,
        0x4E,
        0x47,
        1,
        2,
        3,
        4,
      ], flush: true);
    } else if (args.isNotEmpty && args.first == 'sub-add' && args.length >= 2) {
      final newId = _nextTrackId++;
      final title = args.length >= 4 ? args[3] : '';
      final lang = args.length >= 5 ? args[4] : 'chi';
      tracks.add(
        MpvTrackInfo(
          id: newId,
          type: MpvTrackType.subtitle,
          lang: lang,
          title: title,
          codec: 'ass',
          isExternal: true,
          externalFilename: args[1],
        ),
      );
      if (args.length >= 3 && args[2] == 'select') {
        stringProps['sid'] = '$newId';
      }
    } else if (args.isNotEmpty &&
        args.first == 'sub-remove' &&
        args.length >= 2) {
      final id = int.tryParse(args[1]);
      if (id != null) {
        tracks.removeWhere(
          (t) => t.id == id && t.type == MpvTrackType.subtitle,
        );
      }
    } else if (args.isNotEmpty && args.first == 'loadfile') {
      final eid = _nextPlaylistEntryId++;
      emitEvent(MpvStartFileEvent(eid));
    }
    return MpvError.success;
  }

  @override
  int commandAsync(int replyUserdata, List<String> args) => command(args);

  Uint8List? renderSoftwareFrame({required int width, required int height}) =>
      null;

  @override
  Future<void> dispose() async {
    isDisposed = true;
    await _events.close();
  }
}

/// 纯 Dart 测试用 `LocalStreamBridgePort` 轻量替身。
class FakeLocalStreamBridge implements LocalStreamBridgePort {
  final Map<String, String> activeSessions = <String, String>{};
  final Map<String, VirtualAlbumRegistration> activeAlbums =
      <String, VirtualAlbumRegistration>{};
  int _seq = 0;

  @override
  int? get port => 49152;

  @override
  int get activeSessionCount => activeSessions.length + activeAlbums.length;

  @override
  Future<({String token, Uri url})> registerSession({
    required ByteRangeReadableGateway gateway,
    required String relativePath,
    required String fileName,
    int? knownLength,
    bool ownsGateway = false,
    MediaSourceKind sourceKind = MediaSourceKind.webdav,
  }) async {
    final token = 'tok_${++_seq}';
    activeSessions[token] = relativePath;
    return (
      token: token,
      url: Uri.parse(
        'http://127.0.0.1:49152/stream/$token/${Uri.encodeComponent(fileName)}',
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
    activeSessions.remove(token);
  }

  @override
  Future<VirtualAlbumRegistration> registerCueAlbumSession({
    required ByteRangeReadableGateway gateway,
    required String normalizedCueText,
    required List<VirtualAlbumAudioEntry> audioEntries,
    bool ownsGateway = true,
    MediaSourceKind sourceKind = MediaSourceKind.webdav,
  }) async {
    final token = 'alb_${++_seq}';
    final urls = <Uri>[
      for (final entry in audioEntries)
        Uri.parse(
          'http://127.0.0.1:49152/album/$token/${Uri.encodeComponent(entry.entryFileName)}',
        ),
    ];
    final reg = VirtualAlbumRegistration(
      albumToken: token,
      manifestUrl: Uri.parse('http://127.0.0.1:49152/album/$token/album.cue'),
      primaryAudioUrl: urls.first,
      audioUrls: urls,
    );
    activeAlbums[token] = reg;
    return reg;
  }

  @override
  Future<VirtualAlbumRegistration> registerPlaylistM3u8Session({
    required ByteRangeReadableGateway gateway,
    required List<VirtualAlbumAudioEntry> audioEntries,
    bool ownsGateway = true,
    MediaSourceKind sourceKind = MediaSourceKind.webdav,
  }) async {
    final token = 'm3u_${++_seq}';
    final urls = <Uri>[
      for (final entry in audioEntries)
        Uri.parse(
          'http://127.0.0.1:49152/m3u/$token/${Uri.encodeComponent(entry.entryFileName)}',
        ),
    ];
    final reg = VirtualAlbumRegistration(
      albumToken: token,
      manifestUrl: Uri.parse('http://127.0.0.1:49152/m3u/$token/playlist.m3u8'),
      primaryAudioUrl: urls.first,
      audioUrls: urls,
    );
    activeAlbums[token] = reg;
    return reg;
  }

  @override
  Future<void> unregisterAlbumSession(String albumToken) async {
    activeAlbums.remove(albumToken);
  }

  @override
  Future<List<String>> resolveExistingCachedSubtitles({
    required String workId,
    required List<String> subtitleRelativePaths,
    String? sourceId,
    Map<String, String>? validatorsByPath,
  }) async => const [];

  @override
  Future<List<String>> materializeRemoteSubtitles({
    required ByteRangeReadableGateway gateway,
    required String workId,
    required List<String> subtitleRelativePaths,
    String? sourceId,
    Map<String, String>? validatorsByPath,
  }) async => const [];

  @override
  Future<List<MaterializedSubtitleRecord>> materializeRemoteSubtitleRecords({
    required ByteRangeReadableGateway gateway,
    required String workId,
    required List<String> subtitleRelativePaths,
    String? sourceId,
    Map<String, String>? validatorsByPath,
  }) async => const [];

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
    activeSessions.clear();
    activeAlbums.clear();
  }
}

/// 纯 Dart 测试用 Android 底层表面端口替身。
class FakeAndroidVideoSurfacePort implements AndroidVideoSurfacePort {
  FakeAndroidVideoSurfacePort([this._current]);

  AndroidSurfaceDescriptor? _current;
  final StreamController<AndroidSurfaceDescriptor?> _changes =
      StreamController<AndroidSurfaceDescriptor?>.broadcast();
  bool _disposed = false;
  final List<int> releasedWids = <int>[];

  @override
  AndroidSurfaceDescriptor? get current => _current;

  @override
  Stream<AndroidSurfaceDescriptor?> get surfaceChanges => _changes.stream;

  @override
  bool get isDisposed => _disposed;

  void pushDescriptor(AndroidSurfaceDescriptor? next) {
    _current = next;
    if (!_changes.isClosed) {
      _changes.add(next);
    }
  }

  @override
  Future<void> syncViewportRect({
    required int leftPx,
    required int topPx,
    required int rightPx,
    required int bottomPx,
    double cornerRadiusPx = 0.0,
  }) async {}

  @override
  Future<void> hideViewport() async {}

  @override
  Future<AndroidSurfaceDescriptor?> queryCurrent() async => _current;

  @override
  Future<void> releaseReference(int wid) async {
    releasedWids.add(wid);
  }

  @override
  Future<void> releaseSurface() async {
    _current = null;
  }

  @override
  Future<void> detachWithoutClearingChannel() async {
    await dispose();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await _changes.close();
  }
}

/// 纯 Dart 测试用 Android 音频路由端口替身。
class FakeAndroidAudioRoutePort implements AndroidAudioRoutePort {
  final Map<Object, void Function(String reason)> _removed =
      <Object, void Function(String reason)>{};
  final Map<Object, void Function(String deviceFingerprint)> _added =
      <Object, void Function(String deviceFingerprint)>{};

  AndroidBitPerfectNegotiationResult nextNegotiationResult =
      const AndroidBitPerfectNegotiationResult(
        supported: true,
        engaged: true,
        operationSucceeded: true,
        deviceName: 'Mock USB DAC',
        sampleRateHz: 96000,
      );

  Future<AndroidBitPerfectNegotiationResult> Function(bool enable)? onNegotiate;
  int negotiateCallCount = 0;
  bool? lastNegotiateEnable;

  @override
  void bindRouteListeners({
    required Object owner,
    void Function(String reason)? onOutputDeviceRemoved,
    void Function(String deviceFingerprint)? onOutputDeviceAdded,
  }) {
    if (onOutputDeviceRemoved != null) {
      _removed[owner] = onOutputDeviceRemoved;
    }
    if (onOutputDeviceAdded != null) {
      _added[owner] = onOutputDeviceAdded;
    }
  }

  @override
  void unbindRouteListeners({required Object owner}) {
    _removed.remove(owner);
    _added.remove(owner);
  }

  @override
  Future<AndroidBitPerfectNegotiationResult> negotiateBitPerfectUsb({
    required bool enable,
    int? preferredSampleRateHz,
  }) async {
    negotiateCallCount += 1;
    lastNegotiateEnable = enable;
    final callback = onNegotiate;
    if (callback != null) return callback(enable);
    return nextNegotiationResult;
  }

  void triggerRemoved([String reason = 'headset_unplugged']) {
    for (final cb in List<void Function(String)>.of(_removed.values)) {
      cb(reason);
    }
  }

  void triggerAdded([String fingerprint = 'usb_dac_new']) {
    for (final cb in List<void Function(String)>.of(_added.values)) {
      cb(fingerprint);
    }
  }

  @override
  void dispose() {
    _removed.clear();
    _added.clear();
  }
}
