part of 'lyric_merger.dart';

/// 单次歌词竞速或手动重搜会话内的跨源对齐与预解析缓存。
///
/// 在同一批候选的多次重算间复用清洗结果、行级签名索引、覆盖槽位与对称两两对齐结果，
/// 消除高次复杂度重复解析与重复序列对齐造成的主线程卡顿。
class LyricCrossSourceCache {
  final Map<String, _PreparedLyricTrack> _tracksByLrc = {};
  final Map<int, CrossSourceAlignment> _pairAlignments = {};
  final Map<String, List<TimedLyricEntry>> _auxEntriesCache = {};
  int _nextTrackId = 0;

  /// 获取候选歌词的缓存清洗结果（同一正文仅清洗一次）。
  CleanedLyricResult cleanedFor(LyricCandidate candidate) {
    return _trackForLrc(candidate.lrcContent).cleaned;
  }

  /// 计算或复用两份同步候选的对称跨源原文对齐结果。
  CrossSourceAlignment align(LyricCandidate primary, LyricCandidate other) {
    final trackA = _trackForLrc(primary.lrcContent);
    final trackB = _trackForLrc(other.lrcContent);
    return _alignTracks(trackA, trackB);
  }

  /// 复用缓存对主候选执行跨源一致性验证与缺失译文或罗马音回填。
  CrossSourceEnrichment enrich(
    LyricCandidate primary,
    List<LyricCandidate> others,
  ) {
    if (!primary.isSynced || others.isEmpty) {
      return CrossSourceEnrichment(
        candidate: primary,
        crossSourceAgreed: false,
        borrowedTranslation: false,
        borrowedRomaji: false,
      );
    }

    final primaryTrack = _trackForLrc(primary.lrcContent);
    final primaryMainRows = primaryTrack.primaryRows;
    if (primaryMainRows.isEmpty) {
      return CrossSourceEnrichment(
        candidate: primary,
        crossSourceAgreed: false,
        borrowedTranslation: false,
        borrowedRomaji: false,
      );
    }

    var agreed = false;
    var current = primary;
    var borrowedTrans = false;
    var borrowedRoma = false;
    ({Set<int> transSlots, Set<int> romaSlots})? coverage;

    for (final other in others) {
      if (!other.isSynced || other.source == primary.source) continue;
      final otherTrack = _trackForLrc(other.lrcContent);
      if (otherTrack.primaryRows.isEmpty) continue;

      final canInspectTrans = other.hasTranslation;
      final canInspectRoma = other.hasRomaji;
      if (agreed && !canInspectTrans && !canInspectRoma) {
        continue;
      }

      if (agreed && (canInspectTrans || canInspectRoma)) {
        coverage ??= primaryTrack.initialCoverage;
        final needTrans =
            canInspectTrans &&
            coverage.transSlots.length < primaryMainRows.length;
        final needRoma =
            canInspectRoma &&
            coverage.romaSlots.length < primaryMainRows.length;
        if (!needTrans && !needRoma) continue;
      }

      final align = _alignTracks(primaryTrack, otherTrack);
      if (align.matchRatio >= LyricMerger.crossVerifyMinMatchRatio &&
          align.medianShiftSeconds.abs() <=
              LyricMerger.crossVerifyMaxMedianShiftSeconds) {
        agreed = true;
      }

      if (align.matchRatio < LyricMerger.crossBorrowMinMatchRatio) continue;
      if (!canInspectTrans && !canInspectRoma) continue;

      coverage ??= primaryTrack.initialCoverage;
      List<TimedLyricEntry> transToBorrow = const [];
      if (canInspectTrans &&
          coverage.transSlots.length < primaryMainRows.length) {
        transToBorrow = _translationRowsFor(other, otherTrack);
      }

      List<TimedLyricEntry> romaToBorrow = const [];
      if (canInspectRoma &&
          coverage.romaSlots.length < primaryMainRows.length) {
        romaToBorrow = _romajiRowsFor(other, otherTrack);
      }

      if (transToBorrow.isEmpty && romaToBorrow.isEmpty) continue;

      final merged = LyricMerger._attachBorrowedTracks(
        baseLrc: current.lrcContent,
        baseMainRows: primaryMainRows,
        existingTransSlots: coverage.transSlots,
        existingRomaSlots: coverage.romaSlots,
        translationRows: transToBorrow,
        romajiRows: romaToBorrow,
        timeShiftSeconds: align.medianShiftSeconds,
      );
      if (merged.addedTranslation || merged.addedRomaji) {
        current = current.copyWith(
          lrcContent: merged.lrcContent,
          hasTranslation: current.hasTranslation || merged.addedTranslation,
          hasRomaji: current.hasRomaji || merged.addedRomaji,
        );
        borrowedTrans = borrowedTrans || merged.addedTranslation;
        borrowedRoma = borrowedRoma || merged.addedRomaji;
        coverage = LyricMerger._inspectSlotCoverage(
          current.lrcContent,
          primaryMainRows,
        );
      }
    }

    return CrossSourceEnrichment(
      candidate: current,
      crossSourceAgreed: agreed,
      borrowedTranslation: borrowedTrans,
      borrowedRomaji: borrowedRoma,
    );
  }

  _PreparedLyricTrack _trackForLrc(String lrcContent) {
    return _tracksByLrc.putIfAbsent(
      lrcContent,
      () => _PreparedLyricTrack.fromLrc(_nextTrackId++, lrcContent),
    );
  }

  CrossSourceAlignment _alignTracks(
    _PreparedLyricTrack trackA,
    _PreparedLyricTrack trackB,
  ) {
    if (trackA.primaryRows.isEmpty || trackB.primaryRows.isEmpty) {
      return const CrossSourceAlignment(
        matchRatio: 0.0,
        medianShiftSeconds: 0.0,
        matchedPairs: 0,
      );
    }
    if (trackA.id == trackB.id) {
      return CrossSourceAlignment(
        matchRatio: 1.0,
        medianShiftSeconds: 0.0,
        matchedPairs: trackA.primaryRows.length,
      );
    }
    final swapped = trackA.id > trackB.id;
    final lo = swapped ? trackB : trackA;
    final hi = swapped ? trackA : trackB;
    final pairKey = (lo.id << 24) | hi.id;
    final cached = _pairAlignments.putIfAbsent(
      pairKey,
      () => LyricMerger._alignPreparedTracks(lo, hi),
    );
    if (!swapped) return cached;
    return CrossSourceAlignment(
      matchRatio: cached.matchRatio,
      medianShiftSeconds: cached.medianShiftSeconds == 0.0
          ? 0.0
          : -cached.medianShiftSeconds,
      matchedPairs: cached.matchedPairs,
    );
  }

  List<TimedLyricEntry> _translationRowsFor(
    LyricCandidate other,
    _PreparedLyricTrack track,
  ) {
    if (other.translationLrc.trim().isNotEmpty) {
      return _auxEntriesCache.putIfAbsent(
        't::${other.translationLrc}',
        () => LyricMerger._extractAuxTrackEntries(other.translationLrc),
      );
    }
    return track.embeddedTranslationRows;
  }

  List<TimedLyricEntry> _romajiRowsFor(
    LyricCandidate other,
    _PreparedLyricTrack track,
  ) {
    if (other.romajiLrc.trim().isNotEmpty) {
      return _auxEntriesCache.putIfAbsent(
        'r::${other.romajiLrc}',
        () => LyricMerger._extractAuxTrackEntries(other.romajiLrc),
      );
    }
    return track.embeddedRomajiRows;
  }
}

final class _LineSignature {
  const _LineSignature(
    this.key,
    this.charMask,
    this.bigramMask,
    this.sortedBigrams,
  );

  final String key;
  final int charMask;
  final int bigramMask;
  final Int32List sortedBigrams;

  static final Int32List _empty = Int32List(0);

  factory _LineSignature.fromKey(String key) {
    final len = key.length;
    if (len == 0) return _LineSignature(key, 0, 0, _empty);
    var cMask = 0;
    for (var i = 0; i < len; i++) {
      cMask |= 1 << (key.codeUnitAt(i) & 63);
    }
    if (len < 2) return _LineSignature(key, cMask, 0, _empty);
    final bgLen = len - 1;
    final bg = Int32List(bgLen);
    var bMask = 0;
    var prev = key.codeUnitAt(0);
    for (var i = 0; i < bgLen; i++) {
      final next = key.codeUnitAt(i + 1);
      bg[i] = (prev << 16) | next;
      bMask |= 1 << (((prev * 31) ^ next) & 63);
      prev = next;
    }
    bg.sort();
    return _LineSignature(key, cMask, bMask, bg);
  }
}

final class _PreparedLyricTrack {
  _PreparedLyricTrack._({
    required this.id,
    required this.rawLrc,
    required this.cleaned,
    required this.primaryRows,
  });

  factory _PreparedLyricTrack.fromLrc(int id, String rawLrc) {
    final cleaned = LyricCleaner.clean(rawLrc);
    final rows = cleaned.isPlaceholder ? const <TimedLyricEntry>[] : cleaned.lines;
    return _PreparedLyricTrack._(
      id: id,
      rawLrc: rawLrc,
      cleaned: cleaned,
      primaryRows: rows,
    );
  }

  factory _PreparedLyricTrack.fromRows(int id, List<TimedLyricEntry> rows) {
    return _PreparedLyricTrack._(
      id: id,
      rawLrc: '',
      cleaned: CleanedLyricResult(
        lines: rows,
        credits: const [],
        isPlaceholder: rows.isEmpty,
        cleanedLrc: '',
        outOfOrderRatio: 0.0,
        firstLineSeconds: rows.isEmpty ? null : rows.first.timeSeconds,
        lastLineSeconds: rows.isEmpty ? null : rows.last.timeSeconds,
      ),
      primaryRows: rows,
    );
  }

  final int id;
  final String rawLrc;
  final CleanedLyricResult cleaned;
  final List<TimedLyricEntry> primaryRows;

  List<_LineSignature>? _signatures;
  Map<int, List<int>>? _bigramIndex;
  Map<int, List<int>>? _singleCharIndex;
  ({Set<int> transSlots, Set<int> romaSlots})? _initialCoverage;
  List<TimedLyricEntry>? _embeddedTranslationRows;
  List<TimedLyricEntry>? _embeddedRomajiRows;

  List<_LineSignature> get signatures => _signatures ??= List<_LineSignature>.generate(
    primaryRows.length,
    (i) => _LineSignature.fromKey(
      WorkMatcherScoring.normalizeKey(primaryRows[i].text),
    ),
    growable: false,
  );

  Map<int, List<int>> get bigramIndex {
    if (_bigramIndex == null) _buildInvertedIndex();
    return _bigramIndex!;
  }

  Map<int, List<int>> get singleCharIndex {
    if (_singleCharIndex == null) _buildInvertedIndex();
    return _singleCharIndex!;
  }

  ({Set<int> transSlots, Set<int> romaSlots}) get initialCoverage {
    return _initialCoverage ??= LyricMerger._inspectSlotCoverage(
      rawLrc,
      primaryRows,
    );
  }

  List<TimedLyricEntry> get embeddedTranslationRows {
    return _embeddedTranslationRows ??= LyricMerger.extractTranslationRows(
      rawLrc,
    );
  }

  List<TimedLyricEntry> get embeddedRomajiRows {
    return _embeddedRomajiRows ??= LyricMerger.extractRomajiRows(rawLrc);
  }

  void _buildInvertedIndex() {
    final bgMap = <int, List<int>>{};
    final scMap = <int, List<int>>{};
    final sigs = signatures;
    for (var j = 0; j < sigs.length; j++) {
      final sig = sigs[j];
      if (sig.key.isEmpty) continue;
      if (sig.key.length == 1) {
        scMap.putIfAbsent(sig.key.codeUnitAt(0), () => <int>[]).add(j);
        continue;
      }
      var prev = -1;
      final bg = sig.sortedBigrams;
      for (var k = 0; k < bg.length; k++) {
        final g = bg[k];
        if (g == prev) continue;
        prev = g;
        bgMap.putIfAbsent(g, () => <int>[]).add(j);
      }
    }
    _bigramIndex = bgMap;
    _singleCharIndex = scMap;
  }
}
