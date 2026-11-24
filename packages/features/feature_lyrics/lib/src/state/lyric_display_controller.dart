import 'dart:async';
import 'dart:math' as math;

import 'package:engine_playback/engine_playback.dart';
import 'package:flutter/foundation.dart';
import 'package:konata_contracts/konata_contracts.dart';

import '../data/lyrics_preferences.dart';
import '../data/lyrics_resolver.dart';
import '../domain/lyric_candidate.dart';
import '../domain/lyric_offset_resolver.dart';
import '../domain/lyric_search_query.dart';

/// 沉浸歌词舞台与控制面板共享的不可变状态快照。
@immutable
class LyricDisplayState {
  /// 创建歌词展示状态快照。
  const LyricDisplayState({
    this.activeQuery,
    this.lrcDocument,
    this.activeSpanLines = const <ActiveSpanLyricLine>[],
    this.activeLyricIndex = -1,
    this.activeSource,
    this.activeSourceId = '',
    this.isLookupInFlight = false,
    this.isUserEdited = false,
    this.shortCircuitedInstrumental = false,
    this.offsetSnapshot = LyricOffsetSnapshot.zero,
    this.candidates = const <ScoredLyricCandidate>[],
    this.hasPendingUpgrade = false,
    this.durationSeconds = 0.0,
  });

  static const Object _unset = Object();

  /// 当前活跃曲目的跨包查询描述。
  final LyricTrackQuery? activeQuery;

  /// 已解析的同步歌词文档。
  final LrcDocument? lrcDocument;

  /// 主唱与和声逐字片段列表。
  final List<ActiveSpanLyricLine> activeSpanLines;

  /// 当前时间轴高亮行下标（未入歌前奏期为 `-1`）。
  final int activeLyricIndex;

  /// 当前生效的歌词来源。
  final LyricSource? activeSource;

  /// 当前生效歌词对应的来源内部标识。
  final String activeSourceId;

  /// 是否正在进行在线竞速检索。
  final bool isLookupInFlight;

  /// 当前歌词正文是否由用户手动选定或编辑锁定。
  final bool isUserEdited;

  /// 当前曲目是否被判定为纯音乐或伴奏并短路在线检索。
  final bool shortCircuitedInstrumental;

  /// 当前三级叠加时间轴偏移快照（单曲、专辑、输出路由）。
  final LyricOffsetSnapshot offsetSnapshot;

  /// 最近一次自动或手动检索得到的候选列表（供换候选面板零延迟展示）。
  final List<ScoredLyricCandidate> candidates;

  /// 是否已有高阶候选等待在下一句边界平滑热替换。
  final bool hasPendingUpgrade;

  /// 当前曲目时长（秒）。
  final double durationSeconds;

  /// 复制并覆盖局部状态字段。
  LyricDisplayState copyWith({
    Object? activeQuery = _unset,
    Object? lrcDocument = _unset,
    List<ActiveSpanLyricLine>? activeSpanLines,
    int? activeLyricIndex,
    Object? activeSource = _unset,
    String? activeSourceId,
    bool? isLookupInFlight,
    bool? isUserEdited,
    bool? shortCircuitedInstrumental,
    LyricOffsetSnapshot? offsetSnapshot,
    List<ScoredLyricCandidate>? candidates,
    bool? hasPendingUpgrade,
    double? durationSeconds,
  }) {
    return LyricDisplayState(
      activeQuery: identical(activeQuery, _unset)
          ? this.activeQuery
          : activeQuery as LyricTrackQuery?,
      lrcDocument: identical(lrcDocument, _unset)
          ? this.lrcDocument
          : lrcDocument as LrcDocument?,
      activeSpanLines: activeSpanLines ?? this.activeSpanLines,
      activeLyricIndex: activeLyricIndex ?? this.activeLyricIndex,
      activeSource: identical(activeSource, _unset)
          ? this.activeSource
          : activeSource as LyricSource?,
      activeSourceId: activeSourceId ?? this.activeSourceId,
      isLookupInFlight: isLookupInFlight ?? this.isLookupInFlight,
      isUserEdited: isUserEdited ?? this.isUserEdited,
      shortCircuitedInstrumental:
          shortCircuitedInstrumental ?? this.shortCircuitedInstrumental,
      offsetSnapshot: offsetSnapshot ?? this.offsetSnapshot,
      candidates: candidates ?? this.candidates,
      hasPendingUpgrade: hasPendingUpgrade ?? this.hasPendingUpgrade,
      durationSeconds: durationSeconds ?? this.durationSeconds,
    );
  }
}

/// 歌词模块状态协调控制器（零 Riverpod，实现 [LyricDisplayPort] 供音频舞台解耦协同）。
///
/// 职责边界：
/// - 实现曲目解析、队列分级预取与会话清空端口契约；
/// - 维护候选列表、手动换源、恢复自动匹配与单曲/专辑/输出路由三级偏移调节；
/// - 接收播放位置并在句边界安全热替换渐进升级歌词，不向低频领域事件总线推送高频时钟。
class LyricDisplayController extends ChangeNotifier
    implements LyricDisplayPort {
  /// 构造歌词展示状态控制器。
  LyricDisplayController({
    required this._resolver,
    required this._preferencesStore,
    ValueListenable<Duration>? positionListenable,
    ValueListenable<bool>? isPlayingListenable,
    this._onSeekRequested,
  }) : _externalPosition = positionListenable,
       _externalIsPlaying = isPlayingListenable {
    _preferences = _preferencesStore.read();
    _state = LyricDisplayState(offsetSnapshot: _buildRouteOffsetSnapshot());
    _prefsSub = _preferencesStore.watch().listen(_onPreferencesChanged);
    _externalPosition?.addListener(_onExternalPositionChanged);
    _externalIsPlaying?.addListener(_onExternalPlayingChanged);
  }

  final LyricsResolver _resolver;
  final LyricsPreferencesStore _preferencesStore;
  final ValueListenable<Duration>? _externalPosition;
  final ValueListenable<bool>? _externalIsPlaying;
  final void Function(double targetSeconds, {bool resumePlayback})?
  _onSeekRequested;

  final ValueNotifier<Duration> _internalPosition = ValueNotifier<Duration>(
    Duration.zero,
  );
  final ValueNotifier<bool> _internalIsPlaying = ValueNotifier<bool>(false);

  late LyricDisplayState _state;
  late LyricsPreferences _preferences;
  StreamSubscription<LyricsPreferences>? _prefsSub;

  LyricAudioRouteKind _activeRouteKind = LyricAudioRouteKind.wired;
  LyricResolveOutcome? _pendingUpgrade;
  int _trackGeneration = 0;
  bool _disposed = false;

  /// 当前歌词展示状态快照。
  LyricDisplayState get state => _state;

  /// 当前歌词偏好快照。
  LyricsPreferences get preferences => _preferences;

  /// 供外部或默认歌词扫白叶子直连的播放位置监听句柄。
  ValueListenable<Duration> get positionListenable =>
      _externalPosition ?? _internalPosition;

  /// 供外部或默认歌词扫白叶子直连的播放状态监听句柄。
  ValueListenable<bool> get isPlayingListenable =>
      _externalIsPlaying ?? _internalIsPlaying;

  /// 当前有效播放位置（秒）。
  double get currentPositionSeconds =>
      positionListenable.value.inMicroseconds / 1000000.0;

  @override
  Future<void> resolveForTrack(LyricTrackQuery query) async {
    if (_disposed) return;
    final gen = ++_trackGeneration;
    _pendingUpgrade = null;
    _resolver.cancelPendingLookups();

    final cachedCandidates = _resolver.cachedCandidatesForTrack(query.trackKey);
    _updateState(
      LyricDisplayState(
        activeQuery: query,
        activeLyricIndex: -1,
        offsetSnapshot: _buildRouteOffsetSnapshot(),
        candidates: cachedCandidates,
        durationSeconds: query.durationSeconds,
      ),
    );

    await _resolveInternal(query, generation: gen, bypassCache: false);
  }

  @override
  Future<void> prefetchQueue(List<LyricTrackQuery> upcoming) async {
    if (_disposed || upcoming.isEmpty) return;
    final requests = <LyricResolveRequest>[
      for (final q in upcoming) _toResolveRequest(q),
    ];
    await _resolver.prefetchUpcomingTracks(requests);
  }

  @override
  void clearActive() {
    if (_disposed) return;
    _trackGeneration++;
    _pendingUpgrade = null;
    _resolver.cancelPendingLookups();
    _updateState(
      LyricDisplayState(offsetSnapshot: _buildRouteOffsetSnapshot()),
    );
  }

  /// 宿主主动推送最新播放进度与播放状态（未绑定外部可监听句柄时使用）。
  void updatePlaybackPosition(Duration position, {bool? isPlaying}) {
    if (_disposed) return;
    if (_externalPosition == null && _internalPosition.value != position) {
      _internalPosition.value = position;
    }
    if (isPlaying != null &&
        _externalIsPlaying == null &&
        _internalIsPlaying.value != isPlaying) {
      _internalIsPlaying.value = isPlaying;
    }
    _syncActiveLineAndPendingUpgrade();
  }

  /// 更新当前活跃音频输出设备路由特征，自动在有线与蓝牙全局补偿延迟间切换。
  void updateAudioRoute({String? deviceName, String? deviceFingerprint}) {
    if (_disposed) return;
    final nextKind = LyricOffsetResolver.classifyAudioRoute(
      deviceName: deviceName,
      deviceFingerprint: deviceFingerprint,
    );
    if (nextKind == _activeRouteKind) return;
    _activeRouteKind = nextKind;
    _applyUpdatedOffset(
      _buildRouteOffsetSnapshot(
        trackOffsetMillis: _state.offsetSnapshot.trackOffsetMillis,
        albumOffsetMillis: _state.offsetSnapshot.albumOffsetMillis,
        userOffsetLocked: _state.offsetSnapshot.userOffsetLocked,
      ),
    );
  }

  /// 在指定位置触发曲目跳转（点击中央时间轴定位条或播放图标时调用）。
  void requestSeekToLyricLine(
    double targetSeconds, {
    bool resumeIfPaused = true,
  }) {
    if (_disposed) return;
    final clamped = math.max(0.0, targetSeconds);
    final shouldResume = resumeIfPaused && !isPlayingListenable.value;
    if (_onSeekRequested != null) {
      _onSeekRequested(clamped, resumePlayback: shouldResume);
    } else {
      updatePlaybackPosition(
        Duration(microseconds: (clamped * 1000000).round()),
        isPlaying: shouldResume ? true : null,
      );
    }
  }

  /// 按增量微调单曲歌词偏移（毫秒，正值使歌词提前）并持久化锁定。
  Future<void> adjustTrackOffsetMillis(int deltaMillis) {
    final next = LyricOffsetSnapshot.clampTrackOrAlbum(
      _state.offsetSnapshot.trackOffsetMillis + deltaMillis,
    );
    return setTrackOffsetMillis(next);
  }

  /// 设置当前单曲歌词偏移（毫秒）并持久化。
  Future<void> setTrackOffsetMillis(
    int offsetMillis, {
    bool userOffsetLocked = true,
  }) async {
    final query = _state.activeQuery;
    if (_disposed || query == null) return;
    final clamped = LyricOffsetSnapshot.clampTrackOrAlbum(offsetMillis);
    final locked = userOffsetLocked && clamped != 0;
    _applyUpdatedOffset(
      _state.offsetSnapshot.copyWith(
        trackOffsetMillis: clamped,
        userOffsetLocked: locked,
      ),
    );
    await _resolver.saveTrackOffset(
      query.trackKey,
      offsetMillis: clamped,
      userOffsetLocked: locked,
    );
  }

  /// 设置当前专辑统一歌词偏移（毫秒），作用于同专辑全部曲目并持久化。
  Future<void> setAlbumOffsetMillis(int offsetMillis) async {
    final query = _state.activeQuery;
    if (_disposed || query == null) return;
    final clamped = LyricOffsetSnapshot.clampTrackOrAlbum(offsetMillis);
    _applyUpdatedOffset(
      _state.offsetSnapshot.copyWith(albumOffsetMillis: clamped),
    );
    await _resolver.saveAlbumOffset(query.albumKey ?? '', clamped);
  }

  /// 一键将当前单曲与专辑合成偏移提升为整张专辑统一偏移，同时归零单曲偏移。
  Future<void> promoteCurrentOffsetToAlbum() async {
    final query = _state.activeQuery;
    if (_disposed || query == null) return;
    final combinedAlbumMs = LyricOffsetSnapshot.clampTrackOrAlbum(
      _state.offsetSnapshot.albumOffsetMillis +
          _state.offsetSnapshot.trackOffsetMillis,
    );
    _applyUpdatedOffset(
      _state.offsetSnapshot.copyWith(
        trackOffsetMillis: 0,
        userOffsetLocked: false,
        albumOffsetMillis: combinedAlbumMs,
      ),
    );
    await _resolver.saveAlbumOffset(query.albumKey ?? '', combinedAlbumMs);
    await _resolver.saveTrackOffset(
      query.trackKey,
      offsetMillis: 0,
      userOffsetLocked: false,
    );
  }

  /// 设置指定音频输出路由的全局歌词补偿延迟（毫秒）并实时同步当前活跃路由。
  Future<void> setRouteOffsetMillis(
    LyricAudioRouteKind routeKind,
    int offsetMillis,
  ) async {
    if (_disposed) return;
    final clamped = LyricOffsetSnapshot.clampRoute(offsetMillis);
    _preferencesStore.setRouteOffsetMillis(routeKind, clamped);
    _preferences = _preferencesStore.read();
    if (_activeRouteKind == routeKind) {
      _applyUpdatedOffset(
        _state.offsetSnapshot.copyWith(routeOffsetMillis: clamped),
      );
    } else {
      notifyListeners();
    }
  }

  /// 切换罗马音注音显示偏好并实时生效。
  void setShowRomaji(bool enabled) {
    if (_disposed) return;
    _preferencesStore.setShowRomaji(enabled);
    _preferences = _preferencesStore.read();
    notifyListeners();
  }

  /// 手动输入曲名与歌手关键词重搜全部已启用在线歌词源。
  Future<List<ScoredLyricCandidate>> searchCandidatesManual({
    required String title,
    String artist = '',
  }) async {
    final query = _state.activeQuery;
    if (_disposed || query == null) return const [];
    final gen = _trackGeneration;
    final cleanTitle = title.trim().isEmpty ? query.title : title.trim();
    final durationSec = _state.durationSeconds > 0
        ? _state.durationSeconds
        : (query.durationSeconds > 0 ? query.durationSeconds : null);
    final searchQuery = LyricSearchQuery(
      title: cleanTitle,
      artist: artist.trim(),
      album: query.album,
      fileName: query.fileName,
      durationSeconds: durationSec,
    );
    final results = await _resolver.searchCandidatesManual(
      searchQuery,
      trackKey: query.trackKey,
    );
    if (!_disposed && gen == _trackGeneration) {
      _updateState(_state.copyWith(candidates: results));
    }
    return results;
  }

  /// 手动切换至指定歌词候选并持久化锁定（不被自动流程覆盖）。
  Future<bool> selectCandidate(ScoredLyricCandidate selected) async {
    final query = _state.activeQuery;
    if (_disposed || query == null) return false;
    final gen = _trackGeneration;
    final req = _toResolveRequest(query);
    final outcome = await _resolver.applyManualCandidate(
      trackKey: req.trackKey,
      songKey: req.query.songKey,
      selected: selected,
    );
    if (outcome == null ||
        outcome.lrcDocument == null ||
        _disposed ||
        gen != _trackGeneration) {
      return false;
    }
    _pendingUpgrade = null;
    final doc = outcome.lrcDocument!;
    final mergedCandidates = _state.candidates.any(
          (c) =>
              c.candidate.source == selected.candidate.source &&
              c.candidate.sourceId == selected.candidate.sourceId,
        )
        ? _state.candidates
        : <ScoredLyricCandidate>[selected, ..._state.candidates];

    _updateState(
      _state.copyWith(
        lrcDocument: doc,
        activeSpanLines: outcome.activeSpanLines,
        activeLyricIndex: doc.activeIndexAt(
          currentPositionSeconds + _state.offsetSnapshot.totalOffsetSeconds,
        ),
        activeSource: outcome.source,
        activeSourceId: outcome.sourceId,
        isLookupInFlight: false,
        isUserEdited: true,
        candidates: mergedCandidates,
        hasPendingUpgrade: false,
      ),
    );
    return true;
  }

  /// 解除当前曲目的手动歌词锁定并重新执行自动多源匹配（保留已锁定的偏移）。
  Future<void> resetToAutoMatch() async {
    final query = _state.activeQuery;
    if (_disposed || query == null) return;
    final gen = _trackGeneration;
    _pendingUpgrade = null;
    await _resolver.unlockUserEdit(query.trackKey);
    if (_disposed || gen != _trackGeneration) return;
    _updateState(
      _state.copyWith(isUserEdited: false, hasPendingUpgrade: false),
    );
    await _resolveInternal(query, generation: gen, bypassCache: true);
  }

  Future<void> _resolveInternal(
    LyricTrackQuery query, {
    required int generation,
    required bool bypassCache,
  }) async {
    final req = _toResolveRequest(query);
    unawaited(_hydrateOffsets(query, generation: generation));

    final outcome = await _resolver.resolve(
      req,
      bypassCache: bypassCache,
      onNetworkLookupStarted: () {
        if (_disposed || generation != _trackGeneration) return;
        _updateState(_state.copyWith(isLookupInFlight: true));
      },
      onCandidatesSettled: (allCandidates) {
        if (_disposed || generation != _trackGeneration) return;
        _updateState(_state.copyWith(candidates: allCandidates));
      },
      onProgressiveUpgrade: (upgraded) {
        if (_disposed || generation != _trackGeneration) return;
        if (_state.isUserEdited) return;
        _pendingUpgrade = upgraded;
        if (_state.lrcDocument == null || _state.activeLyricIndex < 0) {
          _consumePendingUpgrade();
        } else {
          _updateState(_state.copyWith(hasPendingUpgrade: true));
        }
      },
    );

    if (_disposed || generation != _trackGeneration || outcome.staleAborted) {
      return;
    }

    final persisted = await _resolver.readPersistedOffsets(
      trackKey: query.trackKey,
      albumKey: query.albumKey ?? '',
    );
    if (_disposed || generation != _trackGeneration) return;

    final resolvedOffset = _buildRouteOffsetSnapshot(
      trackOffsetMillis: outcome.userOffsetLocked
          ? outcome.trackOffsetMillis
          : persisted.trackOffsetMillis,
      albumOffsetMillis: persisted.albumOffsetMillis,
      userOffsetLocked: outcome.userOffsetLocked || persisted.userOffsetLocked,
    );

    final doc = outcome.lrcDocument;
    final nextIndex = doc == null
        ? -1
        : doc.activeIndexAt(
            currentPositionSeconds + resolvedOffset.totalOffsetSeconds,
          );

    _updateState(
      _state.copyWith(
        lrcDocument: doc,
        activeSpanLines: outcome.activeSpanLines,
        activeLyricIndex: nextIndex,
        activeSource: outcome.source,
        activeSourceId: outcome.sourceId,
        isLookupInFlight: false,
        isUserEdited: outcome.userEdited,
        shortCircuitedInstrumental: outcome.shortCircuitedInstrumental,
        offsetSnapshot: resolvedOffset,
        candidates: outcome.candidates.isNotEmpty
            ? outcome.candidates
            : _state.candidates,
      ),
    );
  }

  Future<void> _hydrateOffsets(
    LyricTrackQuery query, {
    required int generation,
  }) async {
    final persisted = await _resolver.readPersistedOffsets(
      trackKey: query.trackKey,
      albumKey: query.albumKey ?? '',
    );
    if (_disposed || generation != _trackGeneration) return;
    final next = _buildRouteOffsetSnapshot(
      trackOffsetMillis: persisted.trackOffsetMillis,
      albumOffsetMillis: persisted.albumOffsetMillis,
      userOffsetLocked: persisted.userOffsetLocked,
    );
    if (next != _state.offsetSnapshot) {
      _applyUpdatedOffset(next);
    }
  }

  void _syncActiveLineAndPendingUpgrade() {
    final doc = _state.lrcDocument;
    if (doc == null) {
      if (_pendingUpgrade != null) {
        _consumePendingUpgrade();
      }
      return;
    }
    final nextIndex = doc.activeIndexAt(
      currentPositionSeconds + _state.offsetSnapshot.totalOffsetSeconds,
    );
    if (nextIndex != _state.activeLyricIndex) {
      if (_pendingUpgrade != null) {
        _consumePendingUpgrade();
        return;
      }
      _updateState(_state.copyWith(activeLyricIndex: nextIndex));
    }
  }

  void _consumePendingUpgrade() {
    final upgraded = _pendingUpgrade;
    if (upgraded == null || upgraded.lrcDocument == null) {
      _pendingUpgrade = null;
      return;
    }
    _pendingUpgrade = null;
    final doc = upgraded.lrcDocument!;
    final nextIndex = doc.activeIndexAt(
      currentPositionSeconds + _state.offsetSnapshot.totalOffsetSeconds,
    );
    _updateState(
      _state.copyWith(
        lrcDocument: doc,
        activeSpanLines: upgraded.activeSpanLines,
        activeLyricIndex: nextIndex,
        activeSource: upgraded.source,
        activeSourceId: upgraded.sourceId,
        hasPendingUpgrade: false,
        candidates: upgraded.candidates.isNotEmpty
            ? upgraded.candidates
            : _state.candidates,
      ),
    );
  }

  void _applyUpdatedOffset(LyricOffsetSnapshot nextOffset) {
    final doc = _state.lrcDocument;
    final nextIndex = doc == null
        ? _state.activeLyricIndex
        : doc.activeIndexAt(
            currentPositionSeconds + nextOffset.totalOffsetSeconds,
          );
    _updateState(
      _state.copyWith(
        offsetSnapshot: nextOffset,
        activeLyricIndex: nextIndex,
      ),
    );
  }

  void _onPreferencesChanged(LyricsPreferences next) {
    if (_disposed) return;
    _preferences = next;
    final nextRouteOffset = LyricOffsetSnapshot.clampRoute(
      next.offsetForRoute(_activeRouteKind),
    );
    if (nextRouteOffset != _state.offsetSnapshot.routeOffsetMillis) {
      _applyUpdatedOffset(
        _state.offsetSnapshot.copyWith(routeOffsetMillis: nextRouteOffset),
      );
    } else {
      notifyListeners();
    }
  }

  void _onExternalPositionChanged() {
    if (_disposed) return;
    _syncActiveLineAndPendingUpgrade();
  }

  void _onExternalPlayingChanged() {
    if (_disposed) return;
    _syncActiveLineAndPendingUpgrade();
  }

  LyricOffsetSnapshot _buildRouteOffsetSnapshot({
    int trackOffsetMillis = 0,
    int albumOffsetMillis = 0,
    bool userOffsetLocked = false,
  }) {
    return LyricOffsetSnapshot(
      trackOffsetMillis: LyricOffsetSnapshot.clampTrackOrAlbum(
        trackOffsetMillis,
      ),
      albumOffsetMillis: LyricOffsetSnapshot.clampTrackOrAlbum(
        albumOffsetMillis,
      ),
      routeOffsetMillis: LyricOffsetSnapshot.clampRoute(
        _preferences.offsetForRoute(_activeRouteKind),
      ),
      activeRouteKind: _activeRouteKind,
      userOffsetLocked: userOffsetLocked,
    );
  }

  static LyricResolveRequest _toResolveRequest(LyricTrackQuery query) {
    return LyricResolveRequest(
      trackKey: query.trackKey,
      albumKey: query.albumKey ?? '',
      bangumiSubjectId: query.bangumiSubjectId,
      trackNumber: query.cueTrackIndex,
      embeddedLrcText: query.embeddedLrcText,
      query: LyricSearchQuery(
        title: query.title,
        artist: query.artist,
        album: query.album,
        fileName: query.fileName,
        durationSeconds:
            query.durationSeconds > 0 ? query.durationSeconds : null,
      ),
    );
  }

  void _updateState(LyricDisplayState next) {
    _state = next;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _trackGeneration++;
    _pendingUpgrade = null;
    _resolver.cancelPendingLookups();
    unawaited(_prefsSub?.cancel());
    _prefsSub = null;
    _externalPosition?.removeListener(_onExternalPositionChanged);
    _externalIsPlaying?.removeListener(_onExternalPlayingChanged);
    _internalPosition.dispose();
    _internalIsPlaying.dispose();
    super.dispose();
  }
}
