import 'dart:math' as math;
import 'dart:typed_data';

/// 从正片视频抽取的单张候选剧照/背景画面样本。
class VideoFrameSample {
  /// 创建视频抽帧样本。
  const VideoFrameSample({
    required this.timestampSeconds,
    required this.imageBytes,
    required this.score,
    required this.width,
    required this.height,
  });

  /// 抽帧对应的视频时间点（秒）。
  final double timestampSeconds;

  /// 编码后的无损位图字节流（PNG）。
  final Uint8List imageBytes;

  /// 视觉信息量综合评分（越高表示主体画面越丰富且远离黑场、纯白与空背景墙）。
  final double score;

  /// 图像像素宽度。
  final int width;

  /// 图像像素高度。
  final int height;

  /// 面向界面的时间点角标文案（如 `04:19` 或 `1:05:12`）。
  String get formattedTimestamp =>
      VideoFrameSamplePlan.formatTimestamp(timestampSeconds);
}

/// 正片视频抽帧采样时间点规划器（避开片头片尾黑场与演职员表，支持多批次错峰抽帧）。
abstract final class VideoFrameSamplePlan {
  static const List<double> _autoRatios = <double>[
    0.14,
    0.28,
    0.44,
    0.60,
    0.74,
  ];

  /// 后台自动择优抽帧的高命中优先采样比例序列（优先直击正片 A/B 段核心剧情区，便于首帧/次帧即高置信度早停）。
  static const List<double> _autoPriorityRatios = <double>[
    0.34,
    0.58,
    0.22,
    0.72,
    0.46,
  ];
  static const List<double> _galleryRatios = <double>[
    0.08,
    0.18,
    0.29,
    0.40,
    0.51,
    0.62,
    0.73,
    0.84,
  ];
  static const List<double> _fallbackSeconds = <double>[
    90.0,
    180.0,
    300.0,
    420.0,
    560.0,
    720.0,
    900.0,
    1140.0,
  ];
  static const List<double> _autoPriorityFallbackSeconds = <double>[
    480.0,
    820.0,
    300.0,
    1020.0,
    640.0,
  ];

  /// 弹窗「换一批」使用的归一化相位偏移表（保证每次切换落在不同的正片时间段）。
  static const List<double> galleryPhaseOffsets = <double>[
    0.0,
    0.045,
    -0.035,
    0.025,
    -0.02,
  ];

  /// 判断路径是否属于旧版自动随机抽取的全屏背景图缓存（`video_frame_auto.png`）。
  static bool isLegacyAutoBackdropPath(String? path) {
    final norm = (path ?? '').replaceAll('\\', '/').toLowerCase();
    return norm.endsWith('/video_frame_auto.png') ||
        norm == 'video_frame_auto.png';
  }

  /// 判断路径是否属于旧版低清自动抽帧单集剧照（需升级为新版智能中心构图或官方剧照）。
  static bool isLegacyAutoEpisodeStillPath(String? path) {
    final norm = (path ?? '').replaceAll('\\', '/').toLowerCase();
    final idx = norm.lastIndexOf('/');
    final fileName = idx >= 0 ? norm.substring(idx + 1) : norm;
    return fileName.startsWith('video_still_') &&
        !fileName.startsWith('video_still_v2_');
  }

  /// 判断路径是否属于任意版本的本地自动视频抽帧剧照（`video_still_*.png`，含 `v2`）。
  static bool isAutoExtractedStillPath(String? path) {
    final norm = (path ?? '').replaceAll('\\', '/').toLowerCase();
    final idx = norm.lastIndexOf('/');
    final fileName = idx >= 0 ? norm.substring(idx + 1) : norm;
    return fileName.startsWith('video_still_') && fileName.endsWith('.png');
  }

  /// 按视频总时长（秒）生成有序不重复的采样时间点列表。
  ///
  /// - [count] `<= 5` 用于后台自动择优补图，覆盖正文多个高密度段落；
  /// - [count] `> 5` 用于「编辑背景图」弹窗多帧挑选，覆盖全片主要段落；
  /// - [phaseOffset] 用于弹窗点击「换一批」时整体错开采样点。
  static List<double> buildTimestamps(
    double? durationSeconds, {
    int count = 5,
    double phaseOffset = 0.0,
  }) {
    final targetCount = count.clamp(1, 8);
    final duration = durationSeconds;
    if (duration == null || !duration.isFinite || duration <= 12.0) {
      final secShift = phaseOffset * 600.0;
      return _fallbackSeconds
          .take(targetCount)
          .map((s) => math.max(15.0, s + secShift))
          .toList(growable: false);
    }

    final baseRatios = targetCount <= _autoRatios.length
        ? _autoRatios.take(targetCount).toList(growable: false)
        : (targetCount == _galleryRatios.length
              ? _galleryRatios
              : List<double>.generate(targetCount, (i) {
                  if (targetCount == 1) return 0.34;
                  return 0.08 + (0.76 * i / (targetCount - 1));
                }));

    final minSec = math.min(8.0, duration * 0.04);
    final maxSec = math.max(minSec, duration - math.min(12.0, duration * 0.06));
    final result = <double>[];
    for (final ratio in baseRatios) {
      final shiftedRatio = (ratio + phaseOffset).clamp(0.05, 0.92);
      final ts = (duration * shiftedRatio).clamp(minSec, maxSec);
      final rounded = (ts * 10).round() / 10.0;
      if (result.isEmpty || (rounded - result.last).abs() >= 2.0) {
        result.add(rounded);
      }
    }
    return result.isEmpty ? <double>[minSec] : result;
  }

  /// 生成面向后台自动单帧择优的高命中优先时间点序列（先探核心剧情段落，命中清晰主体后即可早停跳过剩余远程跳跃）。
  static List<double> buildAutoPriorityTimestamps(
    double? durationSeconds, {
    int count = 5,
  }) {
    final targetCount = count.clamp(1, _autoPriorityRatios.length);
    final duration = durationSeconds;
    if (duration == null || !duration.isFinite || duration <= 12.0) {
      return _autoPriorityFallbackSeconds
          .take(targetCount)
          .toList(growable: false);
    }

    final minSec = math.min(8.0, duration * 0.04);
    final maxSec = math.max(minSec, duration - math.min(12.0, duration * 0.06));
    final result = <double>[];
    for (final ratio in _autoPriorityRatios.take(targetCount)) {
      final ts = (duration * ratio).clamp(minSec, maxSec);
      final rounded = (ts * 10).round() / 10.0;
      if (result.every((existing) => (rounded - existing).abs() >= 2.0)) {
        result.add(rounded);
      }
    }
    return result.isEmpty ? <double>[minSec] : result;
  }

  /// 将秒数格式化为简洁的 `MM:SS` 或 `H:MM:SS` 角标文案。
  static String formatTimestamp(double seconds) {
    final total = seconds.isFinite && seconds > 0 ? seconds.round() : 0;
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }
}

/// 单张视频帧的视觉主体质量指标（供抽帧早停收敛与择优排序复用）。
class VideoFrameQualityMetrics {
  /// 创建视频帧质量指标对象。
  const VideoFrameQualityMetrics({
    required this.score,
    required this.meanLuminance,
    required this.luminanceStd,
    required this.centerEdgeEnergy,
    required this.activeCenterRatio,
    required this.occupiedColorBins,
  });

  /// 无效 BMP 时返回的占位指标。
  static const VideoFrameQualityMetrics invalid = VideoFrameQualityMetrics(
    score: -1.0,
    meanLuminance: 0.0,
    luminanceStd: 0.0,
    centerEdgeEnergy: 0.0,
    activeCenterRatio: 0.0,
    occupiedColorBins: 0,
  );

  /// 综合视觉丰富度评分（无效帧为 `-1`）。
  final double score;

  /// 全画平均亮度（0~1）。
  final double meanLuminance;

  /// 全画亮度标准差。
  final double luminanceStd;

  /// 中心主体构图区平均色彩梯度。
  final double centerEdgeEnergy;

  /// 中心 12 分块中具有明显线条/纹理细节的分块占比（0~1）。
  final double activeCenterRatio;

  /// 中心构图区显著占据的 6×6×6 量化色箱数。
  final int occupiedColorBins;

  /// 是否达到首帧高置信度清晰主体标准（满足时自动抽帧可直接提前收敛，免除后续多次远程 seek）。
  ///
  /// 针对赛璐璐动画色块特征校准：要求中心构图至少半数分块具备清晰线条梯度、显著色箱不少于 8 格且亮度对比均衡，
  /// 既能在首帧命中人物/场景时 1 次 seek 秒停，又能彻底拒收黑场、白屏、纯天空与空黑板镜头。
  bool get isImmediateAccept =>
      score >= 2.45 &&
      activeCenterRatio >= 0.50 &&
      occupiedColorBins >= 8 &&
      centerEdgeEnergy >= 0.055 &&
      meanLuminance >= 0.18 &&
      meanLuminance <= 0.80 &&
      luminanceStd >= 0.10;

  /// 采样满两帧后，当前最佳帧是否已足够清晰丰富以提前收敛。
  bool get isEarlyStopAfterTwo =>
      score >= 1.95 &&
      activeCenterRatio >= 0.40 &&
      occupiedColorBins >= 6 &&
      meanLuminance >= 0.14 &&
      meanLuminance <= 0.84 &&
      luminanceStd >= 0.08;
}

/// 纯领域 24-bit BMP 视频帧视觉主体丰富度评估器。
///
/// 结合中心构图区的线条/色彩梯度、中心分块活跃占比与量化色彩箱多样性，
/// 自动压低黑场、白屏、纯色字幕卡及大面积单调空墙/空黑板/纯天空帧，
/// 优先挑选含清晰动漫人物与丰富场景层次的正片画面。
abstract final class VideoFrameQualityScorer {
  /// 评估 `encodeRgb0ToBmp` 输出的 24-bit BMP 帧质量分数（>= 0，无效 BMP 返回 `-1`）。
  static double scoreBmp24(Uint8List bmpBytes) => evaluateBmp24(bmpBytes).score;

  /// 评估 24-bit BMP 帧的完整视觉主体质量指标（无效 BMP 返回 [VideoFrameQualityMetrics.invalid]）。
  static VideoFrameQualityMetrics evaluateBmp24(Uint8List bmpBytes) {
    if (bmpBytes.length < 54) return VideoFrameQualityMetrics.invalid;
    if (bmpBytes[0] != 0x42 || bmpBytes[1] != 0x4D) {
      return VideoFrameQualityMetrics.invalid;
    }

    final header = ByteData.sublistView(bmpBytes, 0, 54);
    final pixelOffset = header.getUint32(10, Endian.little);
    final width = header.getInt32(18, Endian.little);
    final rawHeight = header.getInt32(22, Endian.little);
    final bpp = header.getUint16(28, Endian.little);
    final height = rawHeight.abs();
    if (width <= 0 || height <= 0 || bpp != 24) {
      return VideoFrameQualityMetrics.invalid;
    }

    final rowStride = ((width * 3) + 3) & ~3;
    final requiredEnd = pixelOffset + rowStride * height;
    if (bmpBytes.length < requiredEnd) return VideoFrameQualityMetrics.invalid;

    // 采样 48×27 网格（1296 像素），单帧耗时低于 0.3ms。
    const gridW = 48;
    const gridH = 27;
    final cols = math.min(gridW, width);
    final rows = math.min(gridH, height);
    final total = cols * rows;
    final lums = Float64List(total);
    final rs = Float64List(total);
    final gs = Float64List(total);
    final bs = Float64List(total);

    var lumSum = 0.0;
    var chromaSum = 0.0;

    for (var gy = 0; gy < rows; gy++) {
      final y = ((gy + 0.5) * height / rows).floor().clamp(0, height - 1);
      final rowBase = pixelOffset + y * rowStride;
      final rowOff = gy * cols;
      for (var gx = 0; gx < cols; gx++) {
        final x = ((gx + 0.5) * width / cols).floor().clamp(0, width - 1);
        final off = rowBase + x * 3;
        final b = bmpBytes[off] / 255.0;
        final g = bmpBytes[off + 1] / 255.0;
        final r = bmpBytes[off + 2] / 255.0;
        final lum = 0.2126 * r + 0.7152 * g + 0.0722 * b;
        final maxC = math.max(r, math.max(g, b));
        final minC = math.min(r, math.min(g, b));

        final idx = rowOff + gx;
        lums[idx] = lum;
        rs[idx] = r;
        gs[idx] = g;
        bs[idx] = b;
        lumSum += lum;
        chromaSum += maxC - minC;
      }
    }
    if (total == 0) return VideoFrameQualityMetrics.invalid;

    final meanLum = lumSum / total;
    final meanChroma = chromaSum / total;

    // 中心主体构图区（剔除上下黑边/字幕条及四周边框，聚焦人物与核心景物所在区域）。
    final cLeft = (cols * 0.16).floor();
    final cRight = math.max(cLeft + 1, (cols * 0.84).ceil());
    final cTop = (rows * 0.14).floor();
    final cBottom = math.max(cTop + 1, (rows * 0.84).ceil());
    final cWidth = cRight - cLeft;
    final cHeight = cBottom - cTop;

    const blockCols = 4;
    const blockRows = 3;
    final blockDetailSum = Float64List(blockCols * blockRows);
    final blockDetailCount = Int32List(blockCols * blockRows);
    final colorHistogram = Int32List(216);

    var varSum = 0.0;
    var centerColorGradSum = 0.0;
    var centerColorGradPairs = 0;
    var centerPixels = 0;

    for (var gy = 0; gy < rows; gy++) {
      final rowOff = gy * cols;
      final inCenterY = gy >= cTop && gy < cBottom;
      for (var gx = 0; gx < cols; gx++) {
        final idx = rowOff + gx;
        final d = lums[idx] - meanLum;
        varSum += d * d;

        if (!inCenterY || gx < cLeft || gx >= cRight) continue;
        centerPixels++;

        final rBin = (rs[idx] * 6).floor().clamp(0, 5);
        final gBin = (gs[idx] * 6).floor().clamp(0, 5);
        final bBin = (bs[idx] * 6).floor().clamp(0, 5);
        colorHistogram[rBin * 36 + gBin * 6 + bBin]++;

        final bx = (((gx - cLeft) * blockCols) ~/ cWidth).clamp(
          0,
          blockCols - 1,
        );
        final by = (((gy - cTop) * blockRows) ~/ cHeight).clamp(
          0,
          blockRows - 1,
        );
        final bIdx = by * blockCols + bx;

        if (gx + 1 < cRight) {
          final nIdx = idx + 1;
          final grad =
              ((rs[idx] - rs[nIdx]).abs() +
                  (gs[idx] - gs[nIdx]).abs() +
                  (bs[idx] - bs[nIdx]).abs()) /
              3.0;
          centerColorGradSum += grad;
          centerColorGradPairs++;
          blockDetailSum[bIdx] += grad;
          blockDetailCount[bIdx]++;
        }
        if (gy + 1 < cBottom) {
          final nIdx = idx + cols;
          final grad =
              ((rs[idx] - rs[nIdx]).abs() +
                  (gs[idx] - gs[nIdx]).abs() +
                  (bs[idx] - bs[nIdx]).abs()) /
              3.0;
          centerColorGradSum += grad;
          centerColorGradPairs++;
          blockDetailSum[bIdx] += grad;
          blockDetailCount[bIdx]++;
        }
      }
    }

    final lumStd = math.sqrt(varSum / total);
    final centerEdgeEnergy = centerColorGradPairs > 0
        ? centerColorGradSum / centerColorGradPairs
        : 0.0;

    // 统计中心 12 个分块中真正具有有效细节（非平坦色块）的比例。
    var activeBlocks = 0;
    var validBlocks = 0;
    for (var i = 0; i < blockCols * blockRows; i++) {
      if (blockDetailCount[i] == 0) continue;
      validBlocks++;
      final avgGrad = blockDetailSum[i] / blockDetailCount[i];
      if (avgGrad >= 0.045) {
        activeBlocks++;
      }
    }
    final activeCenterRatio = validBlocks > 0
        ? activeBlocks / validBlocks
        : 0.0;

    // 统计中心区域显著占据的色彩箱数量（空黑板/纯天空仅占 2~5 格，人物构图通常占 14~40 格）。
    final minBinPixels = math.max(3, (centerPixels * 0.005).round());
    var occupiedBins = 0;
    for (var i = 0; i < colorHistogram.length; i++) {
      if (colorHistogram[i] >= minBinPixels) {
        occupiedBins++;
      }
    }
    final colorRichness = (occupiedBins / 22.0).clamp(0.0, 1.0);

    // 亮度居中（0.20~0.76）最适合作为清晰剧照与背景原画，极端过暗或过亮施加惩罚。
    final lumBalance = 1.0 - ((meanLum - 0.46).abs() / 0.50).clamp(0.0, 1.0);

    var score =
        centerEdgeEnergy * 3.8 +
        activeCenterRatio * 1.65 +
        colorRichness * 1.45 +
        lumStd * 1.15 +
        meanChroma * 0.85 +
        lumBalance * 0.35;

    // 显著压低全黑场、全白闪屏及极低方差单色底板。
    if (meanLum < 0.08 || meanLum > 0.93 || lumStd < 0.05) {
      score *= 0.08;
    } else if (activeCenterRatio < 0.25 && centerEdgeEnergy < 0.045) {
      // 严厉惩罚中心主体空洞的静态空墙、空黑板或纯色天空镜头。
      score *= 0.22;
    }
    return VideoFrameQualityMetrics(
      score: score,
      meanLuminance: meanLum,
      luminanceStd: lumStd,
      centerEdgeEnergy: centerEdgeEnergy,
      activeCenterRatio: activeCenterRatio,
      occupiedColorBins: occupiedBins,
    );
  }
}
