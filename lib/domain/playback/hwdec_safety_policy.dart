/// 解码硬件平台类别（纯领域值类型，严禁依赖 `dart:io`）。
enum HwdecPlatformKind {
  /// Android 平台（`MediaCodec` 硬件解码路径）。
  android,

  /// Windows 平台（`d3d11va` 硬件解码路径）。
  windows,

  /// 其他桌面或未知平台。
  other,
}

/// 解码层硬件解码安全判定结果。
class HwdecSafetyDecision {
  /// 创建硬件解码安全判定结果。
  const HwdecSafetyDecision({
    required this.allowHardwareDecode,
    this.matchedRule,
    this.reason,
  });

  /// 允许保持硬件解码的安全通行结果。
  const HwdecSafetyDecision.allow()
    : allowHardwareDecode = true,
      matchedRule = null,
      reason = null;

  /// 是否允许继续使用硬件解码；`false` 表示必须立即切至多线程 SIMD 软解以防绿屏花屏。
  final bool allowHardwareDecode;

  /// 触发拦截的规则标识（供诊断日志与自动化测试核验）。
  final String? matchedRule;

  /// 面向用户的简体中文降级提示说明。
  final String? reason;
}

/// 视频流解码层安全拦截策略（纯领域规则）。
///
/// 针对 Android `MediaCodec` 与桌面硬件解码器普遍假支持或高危花屏的番剧原盘编码规格
/// （如 AVC Hi10P / 4:2:2 / 4:4:4、HEVC Rext / 非 4:2:0 / 12-bit、VP9/AV1 12-bit），
/// 在解码器初始化与流重配置阶段直接判定回落多线程软解，无需额外网络预读容器头即可全格式通杀。
class HwdecSafetyPolicy {
  HwdecSafetyPolicy._();

  /// Android 安全硬解白名单编解码器集合。
  static const String safeAndroidHwdecCodecs =
      'h264,hevc,mpeg4,mpeg2video,vp8,vp9,av1';

  /// 根据入库已解析的结构化视频编码与位深，在装载前预判是否应直接绕过硬解。
  ///
  /// 仅当结构化 `videoCodec` 存在时生效，避免对未解析文件名的普通样本误判；
  /// 命中时可阻止 Android `MediaCodec` + `AImageReader` 对 Hi10P / HEVC Rext 等伪支持流进行无效初始化。
  static HwdecSafetyDecision evaluateVariantMetadata({
    required HwdecPlatformKind platform,
    String? videoCodec,
    String? bitDepth,
  }) {
    final codec = (videoCodec ?? '').trim();
    if (codec.isEmpty) {
      return const HwdecSafetyDecision.allow();
    }
    return evaluate(
      platform: platform,
      videoCodec: codec,
      pixelFormat: bitDepth,
    );
  }

  /// 根据平台与流编码参数判定是否应拦截硬解并自动切换多线程软解。
  static HwdecSafetyDecision evaluate({
    required HwdecPlatformKind platform,
    required String videoCodec,
    String? videoProfile,
    String? pixelFormat,
    String? hwPixelFormat,
  }) {
    final codec = _normalizeCodec(videoCodec);
    if (codec.isEmpty) {
      return const HwdecSafetyDecision.allow();
    }

    final profile = (videoProfile ?? '').trim().toLowerCase();
    final pixfmt = (pixelFormat ?? '').trim().toLowerCase();
    final hwPixfmt = (hwPixelFormat ?? '').trim().toLowerCase();
    final combinedPixfmt = '$pixfmt $hwPixfmt';

    final is10Bit = _containsAny(combinedPixfmt, const [
      'p10',
      'p010',
      '10le',
      '10be',
      '10bit',
    ]);
    final is12OrHigherBit = _containsAny(combinedPixfmt, const [
      'p12',
      'p012',
      '12le',
      '12be',
      '12bit',
      'p14',
      'p16',
      'p016',
      '16le',
      '16be',
    ]);
    final is422 = _containsAny(combinedPixfmt, const ['422', 'yuyv', 'uyvy']);
    final is444OrRgb = _containsAny(combinedPixfmt, const [
      '444',
      'gbrp',
      'gbrap',
      'rgb',
      'bgr',
      'ayuv',
      'y410',
      'y416',
    ]);

    // 1. H.264 / AVC：全端拦截 Hi10P（10-bit）及 4:2:2 / 4:4:4 番剧非标硬解，避免 MediaCodec 绿屏与花屏。
    // 注意：严禁使用裸 `contains('10')`，否则会把 H.264 规范全称 "MPEG-4 part 10" 误判为 10-bit！
    if (codec == 'h264') {
      final isHi10Profile =
          profile.contains('high 10') ||
          profile.contains('high10') ||
          profile.contains('hi10') ||
          profile.contains('10-bit') ||
          profile.contains('10bit');
      final isHigh422Profile =
          profile.contains('4:2:2') || profile.contains('422');
      final isHigh444Profile =
          profile.contains('4:4:4') || profile.contains('444');
      if (isHi10Profile || is10Bit || is12OrHigherBit) {
        return const HwdecSafetyDecision(
          allowHardwareDecode: false,
          matchedRule: 'avc_hi10p',
          reason: '检测到 H.264 10-bit (Hi10P) 视频流，已自动切换多线程软解防止绿屏花屏',
        );
      }
      if (isHigh422Profile || isHigh444Profile || is422 || is444OrRgb) {
        return const HwdecSafetyDecision(
          allowHardwareDecode: false,
          matchedRule: 'avc_non_420',
          reason: '检测到 H.264 非 4:2:0 色度采样流，已自动切换多线程软解保障画面准确',
        );
      }
      return const HwdecSafetyDecision.allow();
    }

    // 2. HEVC / H.265：Main / Main 10 (4:2:0 10-bit) 放行硬解；拦截 Rext / 4:2:2 / 4:4:4 / >10-bit。
    if (codec == 'hevc') {
      final isRextProfile =
          profile.contains('rext') ||
          profile.contains('range extension') ||
          profile.contains('4:2:2') ||
          profile.contains('4:4:4') ||
          profile.contains('main 12') ||
          profile.contains('monochrome');
      if (is12OrHigherBit || profile.contains('main 12')) {
        return const HwdecSafetyDecision(
          allowHardwareDecode: false,
          matchedRule: 'hevc_gt10bit',
          reason: '检测到 HEVC 高于 10-bit 位深流，已自动切换多线程软解',
        );
      }
      if (platform == HwdecPlatformKind.android &&
          (isRextProfile || is422 || is444OrRgb)) {
        return const HwdecSafetyDecision(
          allowHardwareDecode: false,
          matchedRule: 'hevc_rext_android',
          reason: '检测到 HEVC Rext / 非 4:2:0 视频流，已自动切换多线程软解防止首帧花屏',
        );
      }
      if (platform == HwdecPlatformKind.windows &&
          (is444OrRgb || profile.contains('4:4:4'))) {
        return const HwdecSafetyDecision(
          allowHardwareDecode: false,
          matchedRule: 'hevc_444_windows',
          reason: '检测到 HEVC 4:4:4 视频流，已自动切换多线程软解',
        );
      }
      return const HwdecSafetyDecision.allow();
    }

    // 3. VP9 / AV1：Android 拦截 12-bit 或 4:4:4 高阶 Profile。
    if (platform == HwdecPlatformKind.android &&
        (codec == 'vp9' || codec == 'av1')) {
      final isUnsupportedHighProfile =
          profile.contains('profile 3') ||
          profile.contains('professional') ||
          is12OrHigherBit ||
          is422 ||
          is444OrRgb;
      if (isUnsupportedHighProfile) {
        return HwdecSafetyDecision(
          allowHardwareDecode: false,
          matchedRule: '${codec}_high_profile_android',
          reason: '检测到 ${codec.toUpperCase()} 高阶色度/位深流，已自动切换多线程软解',
        );
      }
    }

    return const HwdecSafetyDecision.allow();
  }

  static String _normalizeCodec(String raw) {
    final lower = raw.trim().toLowerCase();
    if (lower.isEmpty) return '';
    if (lower.contains('h264') ||
        lower.contains('avc') ||
        lower.contains('x264')) {
      return 'h264';
    }
    if (lower.contains('hevc') ||
        lower.contains('h265') ||
        lower.contains('x265')) {
      return 'hevc';
    }
    if (lower.contains('av1') || lower.contains('av01')) {
      return 'av1';
    }
    if (lower.contains('vp9')) {
      return 'vp9';
    }
    return lower;
  }

  static bool _containsAny(String haystack, List<String> needles) {
    for (final needle in needles) {
      if (haystack.contains(needle)) return true;
    }
    return false;
  }
}
