/// 音视频播放领域通用纯文本格式化工具集。
///
/// 全局唯一实现，禁止在 UI、Notifier 或基础设施层私有重写时间/采样率/码率格式化。
class PlaybackFormatters {
  PlaybackFormatters._();

  /// 将秒数格式化为 `MM:SS` 或 `HH:MM:SS`。
  static String formatMediaDuration(
    double rawSeconds, {
    bool alwaysShowHours = false,
  }) {
    if (!rawSeconds.isFinite || rawSeconds <= 0) {
      return alwaysShowHours ? '00:00:00' : '00:00';
    }
    final totalSeconds = rawSeconds.floor();
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    final mm = minutes.toString().padLeft(2, '0');
    final ss = seconds.toString().padLeft(2, '0');
    if (hours > 0 || alwaysShowHours) {
      final hh = hours.toString().padLeft(2, '0');
      return '$hh:$mm:$ss';
    }
    return '$mm:$ss';
  }

  /// 将 `Duration` 格式化为 `MM:SS` 或 `HH:MM:SS`。
  static String formatDuration(
    Duration duration, {
    bool alwaysShowHours = false,
  }) {
    return formatMediaDuration(
      duration.inMilliseconds / 1000.0,
      alwaysShowHours: alwaysShowHours,
    );
  }

  /// 格式化毫秒时长为 `MM:SS`。
  static String formatDurationMillis(int milliseconds) {
    return formatMediaDuration(milliseconds / 1000.0);
  }

  /// 格式化视频/音频码率（bps -> `Mbps` / `kbps`）。
  static String formatBitrate(int? bitsPerSecond) {
    if (bitsPerSecond == null || bitsPerSecond <= 0) return '-';
    if (bitsPerSecond >= 1000 * 1000) {
      return '${(bitsPerSecond / (1000 * 1000)).toStringAsFixed(1)} Mbps';
    }
    if (bitsPerSecond >= 1000) {
      return '${(bitsPerSecond / 1000).round()} kbps';
    }
    return '$bitsPerSecond bps';
  }

  /// 格式化网络/缓存速率（bytes/s -> `MB/s` / `KB/s`）。
  static String formatByteSpeed(int? bytesPerSecond) {
    if (bytesPerSecond == null || bytesPerSecond <= 0) return '0 KB/s';
    const mb = 1024 * 1024;
    if (bytesPerSecond >= mb) {
      return '${(bytesPerSecond / mb).toStringAsFixed(1)} MB/s';
    }
    if (bytesPerSecond >= 1024) {
      return '${(bytesPerSecond / 1024).round()} KB/s';
    }
    return '$bytesPerSecond B/s';
  }

  /// 格式化缓存占用字节数（`MB` / `KB`）。
  static String formatCacheBytes(int? bytes) {
    if (bytes == null || bytes <= 0) return '0 MB';
    const gb = 1024 * 1024 * 1024;
    const mb = 1024 * 1024;
    if (bytes >= gb) {
      return '${(bytes / gb).toStringAsFixed(2)} GB';
    }
    if (bytes >= mb) {
      return '${(bytes / mb).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).round()} KB';
    }
    return '$bytes B';
  }

  /// 格式化音频采样率（如 `48 kHz`、`44.1 kHz`、`96 kHz`、`192 kHz`）。
  static String formatSampleRate(int? hz) {
    if (hz == null || hz <= 0) return '';
    final khz = hz / 1000.0;
    if ((hz % 1000) == 0) {
      return '${khz.toStringAsFixed(0)} kHz';
    }
    return '${khz.toStringAsFixed(1)} kHz';
  }

  /// 格式化音频声道规格文本。
  static String formatChannelLayout(String? layout, int? count) {
    final trimmed = (layout ?? '').trim();
    if (trimmed.isNotEmpty) {
      final lower = trimmed.toLowerCase();
      if (lower == 'stereo') return '2.0';
      if (lower == 'mono') return '1.0';
      if (lower.startsWith('5.1')) return '5.1';
      if (lower.startsWith('7.1')) return '7.1';
      return trimmed;
    }
    if (count == null || count <= 0) return '';
    return switch (count) {
      1 => '1.0',
      2 => '2.0',
      6 => '5.1',
      8 => '7.1',
      _ => '${count}ch',
    };
  }

  /// 从解码像素格式或采样格式推导标准色深/位深标签（如 `10bit` / `8bit` / `24-bit`）。
  static String formatVideoBitDepthLabel(String? pixelFormat) {
    final raw = (pixelFormat ?? '').trim().toLowerCase();
    if (raw.isEmpty) return '';
    // NV12 等名称中的数字是采样布局标识，不是单通道位深。
    if (const {'nv12', 'nv21', 'nv16', 'nv24', 'nv42'}.contains(raw)) {
      return '8bit';
    }
    final semiPlanar = RegExp(r'^p[024]([0-9]{2})(?:le|be)?$').firstMatch(raw);
    if (semiPlanar != null) {
      final depth = semiPlanar.group(1);
      if (const {'10', '12', '16'}.contains(depth)) return '${depth}bit';
    }
    final planar = RegExp(
      r'^(?:yuv[a-z]*\d{3}p|gbrap?|gray|ya)(9|10|12|14|16)(?:le|be)?$',
    ).firstMatch(raw);
    if (planar != null) return '${planar.group(1)}bit';
    if (RegExp(
      r'^(?:rgb|bgr)48(?:le|be)?$|^(?:rgba|bgra)64(?:le|be)?$',
    ).hasMatch(raw)) {
      return '16bit';
    }
    if (const {
      'x2rgb10le',
      'x2bgr10le',
      'y210',
      'y410',
      'rgb30',
      'bgr30',
    }.contains(raw)) {
      return '10bit';
    }
    if (RegExp(
      r'^(?:yuvj?\d{3}p|yuva\d{3}p|gbrap?|gray8|rgb24|bgr24|rgba|bgra|argb|abgr|yuyv422|uyvy422)$',
    ).hasMatch(raw)) {
      return '8bit';
    }
    return '';
  }

  /// 将分辨率宽高映射为规范短标签（如 `2160p`、`1080p`、`720p`）。
  static String formatResolutionBadge(int? width, int? height) {
    if (width == null || height == null || width <= 0 || height <= 0) {
      return '';
    }
    final maxDim = width > height ? width : height;
    final minDim = width < height ? width : height;
    if (maxDim >= 3800 || minDim >= 2100) return '2160p';
    if (maxDim >= 2500 || minDim >= 1400) return '1440p';
    if (maxDim >= 1880 || minDim >= 1040) return '1080p';
    if (maxDim >= 1240 || minDim >= 700) return '720p';
    if (minDim >= 540) return '576p';
    if (minDim >= 460) return '480p';
    return '${width}x$height';
  }

  /// 标准化编解码器短展示名（用于实时规格徽标）。
  static String formatCodecShortLabel(String? codec) {
    final raw = (codec ?? '').trim().toUpperCase();
    if (raw.isEmpty) return '';
    if (raw == 'H265' || raw == 'H.265' || RegExp(r'\bHEVC\b').hasMatch(raw)) {
      return 'HEVC';
    }
    if (raw == 'H264' || raw == 'H.264' || RegExp(r'\bAVC\b').hasMatch(raw)) {
      return 'AVC';
    }
    if (raw.startsWith('PCM_S24')) return 'PCM 24-bit';
    if (raw.startsWith('PCM_S16')) return 'PCM 16-bit';
    if (raw.startsWith('PCM_S32') || raw.startsWith('PCM_F32')) {
      return 'PCM 32-bit';
    }
    if (raw == 'TRUEHD') return 'TrueHD';
    if (raw == 'EAC3') return 'DD+';
    if (raw == 'AC3') return 'AC3';
    return raw;
  }

  /// 格式化音频格式标签（位深与采样率组合，如 `24-bit / 96 kHz`）。
  static String formatAudioSpecSummary({
    String? codec,
    int? sampleRateHz,
    int? channelCount,
    String? channelLayout,
    String? audioFormat,
  }) {
    final parts = <String>[];
    final codecLabel = formatCodecShortLabel(codec);
    if (codecLabel.isNotEmpty) {
      parts.add(codecLabel);
    }
    final fmt = (audioFormat ?? '').trim().toLowerCase();
    if (fmt == 's24' || fmt == 's24p') {
      parts.add('24-bit');
    } else if (fmt == 's16' || fmt == 's16p') {
      parts.add('16-bit');
    } else if (fmt == 's32' ||
        fmt == 's32p' ||
        fmt == 'float' ||
        fmt == 'flt' ||
        fmt == 'fltp') {
      parts.add('32-bit');
    }
    final rateLabel = formatSampleRate(sampleRateHz);
    if (rateLabel.isNotEmpty) {
      parts.add(rateLabel);
    }
    final chLabel = formatChannelLayout(channelLayout, channelCount);
    if (chLabel.isNotEmpty) {
      parts.add(chLabel);
    }
    return parts.join(' · ');
  }
}
