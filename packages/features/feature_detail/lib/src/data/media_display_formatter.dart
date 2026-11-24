import 'package:engine_scraping/engine_scraping.dart';

/// 详情页剧集与媒体信息统一格式化工具（零界面框架依赖，纯字符规整）。
abstract final class MediaDisplayFormatter {
  static final RegExp _trailingVersionTagPattern = RegExp(
    r'\s*(?:\[(?:v\d+|rev|remux|repack)\]|v\d+)$',
    caseSensitive: false,
  );
  static final RegExp _filenameBoundaryPattern = RegExp(
    r'([._\-/\[\]\(\)@&+=,])',
  );

  /// 仅允许对独立数字、季集编码与无意义压制标记执行字符规整；保留完整动画标题。
  static String formatBytes(int bytes) {
    if (bytes <= 0) return '';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unitIdx = 0;
    while (value >= 1024 && unitIdx < units.length - 1) {
      value /= 1024;
      unitIdx++;
    }
    final digits = unitIdx >= 2 ? (value >= 100 ? 0 : 1) : 0;
    return '${value.toStringAsFixed(digits)} ${units[unitIdx]}';
  }

  /// 将原始文件名在常见定界符后插入零宽空格，允许窄屏或卡片两行内按词素自然断行。
  static String formatWrappableFileName(String fileName) {
    final trimmed = fileName.trim();
    if (trimmed.isEmpty) return '';
    return trimmed.replaceAllMapped(
      _filenameBoundaryPattern,
      (m) => '${m.group(1)}\u200B',
    );
  }

  /// 提取小写去点后的大写扩展名标签（如 `MKV`、`FLAC`、`PNG`）。
  static String fileExtensionUpper(String fileName) {
    final trimmed = fileName.trim();
    final dot = trimmed.lastIndexOf('.');
    if (dot <= 0 || dot >= trimmed.length - 1) return '';
    return trimmed.substring(dot + 1).toUpperCase();
  }

  /// 规整多版本规格标签组，生成简洁可控的技术规格徽章文本列表。
  static List<String> buildVariantTechTags(MediaVariant variant) {
    final tags = <String>[];
    final release = variant.releaseGroup?.trim();
    if (release != null && release.isNotEmpty) {
      tags.add(release.replaceAll(_trailingVersionTagPattern, '').trim());
    }
    final resolution = variant.resolution?.trim();
    if (resolution != null && resolution.isNotEmpty) {
      tags.add(resolution);
    }
    final videoCodec = variant.videoCodec?.trim();
    if (videoCodec != null && videoCodec.isNotEmpty) {
      tags.add(videoCodec);
    }
    final bitDepth = variant.bitDepth?.trim();
    if (bitDepth != null && bitDepth.isNotEmpty) {
      tags.add(bitDepth);
    }
    final audioCodec = variant.audioCodec?.trim();
    if (audioCodec != null && audioCodec.isNotEmpty) {
      tags.add(audioCodec);
    }
    return tags;
  }

  /// 从物理版本列表中收集可读压制组 / 字幕组主标签。
  static String formatVariantDisplayLabel(
    MediaVariant variant, {
    MediaSource? source,
  }) {
    final parts = <String>[];
    final rg = variant.releaseGroup?.trim();
    if (rg != null && rg.isNotEmpty) parts.add(rg);
    final sg = variant.subtitleGroup?.trim();
    if (sg != null && sg.isNotEmpty && sg != rg) parts.add(sg);
    final res = variant.resolution?.trim();
    if (res != null && res.isNotEmpty) parts.add(res);
    if (parts.isEmpty) {
      parts.add(variant.fileName);
    }
    if (source != null) {
      parts.add(formatSourceKindShort(source.kind));
    }
    return parts.join(' · ');
  }

  /// 将媒体源协议类型映射为简短中文标签。
  static String formatSourceKindShort(MediaSourceKind kind) {
    return switch (kind) {
      MediaSourceKind.local => '本地',
      MediaSourceKind.webdav => 'WebDAV',
      MediaSourceKind.smb => 'SMB',
    };
  }

  /// 将媒体源协议类型映射为完整说明文本。
  static String formatSourceKindLong(MediaSourceKind kind) {
    return switch (kind) {
      MediaSourceKind.local => '本地磁盘',
      MediaSourceKind.webdav => 'WebDAV 网盘',
      MediaSourceKind.smb => 'SMB 局域网共享',
    };
  }

  /// 计算播放进度条比例（`0.0 ~ 1.0`）。
  static double computeProgressFraction(PlaybackRecord? record) {
    if (record == null) return 0.0;
    if (record.isCompleted) return 1.0;
    if (record.durationSeconds <= 0) return 0.0;
    return (record.positionSeconds / record.durationSeconds).clamp(0.0, 1.0);
  }

  /// 格式化播放剩余或当前时长标签（如 `05:24 / 23:40`）。
  static String formatDurationSeconds(int seconds) {
    if (seconds <= 0) return '00:00';
    final hours = seconds ~/ 3600;
    final mins = (seconds % 3600) ~/ 60;
    final secs = seconds % 60;
    final mm = mins.toString().padLeft(2, '0');
    final ss = secs.toString().padLeft(2, '0');
    if (hours > 0) {
      return '$hours:$mm:$ss';
    }
    return '$mm:$ss';
  }
}
