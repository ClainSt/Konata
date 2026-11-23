/// 音频输出路由大类（用于区分有线/扬声器与蓝牙 A2DP 延迟的全局歌词偏移）。
enum LyricAudioRouteKind {
  /// 有线耳机、内置扬声器或 USB DAC。
  wired('有线 / 扬声器'),

  /// 蓝牙无线耳机或音箱（存在编码缓冲延迟，通常需要正向提前歌词）。
  bluetooth('蓝牙音频');

  const LyricAudioRouteKind(this.label);

  /// 面向用户的简体中文路由名称。
  final String label;
}

/// 当前曲目生效的三级歌词时间轴偏移快照（单曲 + 专辑 + 输出路由，正值表示歌词提前）。
class LyricOffsetSnapshot {
  /// 单曲或专辑偏移允许调节范围上限（毫秒，±15 秒）。
  static const int maxTrackOrAlbumOffsetMillis = 15000;

  /// 输出路由级全局延迟允许调节范围上限（毫秒，±5 秒）。
  static const int maxRouteOffsetMillis = 5000;

  /// 默认零偏移快照。
  static const LyricOffsetSnapshot zero = LyricOffsetSnapshot();

  /// 创建三级偏移快照。
  const LyricOffsetSnapshot({
    this.trackOffsetMillis = 0,
    this.albumOffsetMillis = 0,
    this.routeOffsetMillis = 0,
    this.activeRouteKind = LyricAudioRouteKind.wired,
    this.userOffsetLocked = false,
  });

  /// 单曲级手动偏移（毫秒，正值歌词提前、负值歌词延后）。
  final int trackOffsetMillis;

  /// 专辑级统一偏移（毫秒，作用于同一专辑下全部曲目）。
  final int albumOffsetMillis;

  /// 当前生效音频输出路由（有线或蓝牙）的全局补偿延迟（毫秒）。
  final int routeOffsetMillis;

  /// 当前识别到的活跃音频输出路由大类。
  final LyricAudioRouteKind activeRouteKind;

  /// 单曲偏移是否已由用户主动锁定。
  final bool userOffsetLocked;

  /// 三级叠加后的总偏移（毫秒）。
  int get totalOffsetMillis =>
      trackOffsetMillis + albumOffsetMillis + routeOffsetMillis;

  /// 三级叠加后的总偏移（秒，正值使歌词提前展示）。
  double get totalOffsetSeconds => totalOffsetMillis / 1000.0;

  /// 钳制单曲或专辑偏移至安全区间。
  static int clampTrackOrAlbum(int millis) =>
      millis.clamp(-maxTrackOrAlbumOffsetMillis, maxTrackOrAlbumOffsetMillis);

  /// 钳制输出路由级全局偏移至安全区间。
  static int clampRoute(int millis) =>
      millis.clamp(-maxRouteOffsetMillis, maxRouteOffsetMillis);

  /// 复制并覆盖局部字段。
  LyricOffsetSnapshot copyWith({
    int? trackOffsetMillis,
    int? albumOffsetMillis,
    int? routeOffsetMillis,
    LyricAudioRouteKind? activeRouteKind,
    bool? userOffsetLocked,
  }) {
    return LyricOffsetSnapshot(
      trackOffsetMillis: trackOffsetMillis ?? this.trackOffsetMillis,
      albumOffsetMillis: albumOffsetMillis ?? this.albumOffsetMillis,
      routeOffsetMillis: routeOffsetMillis ?? this.routeOffsetMillis,
      activeRouteKind: activeRouteKind ?? this.activeRouteKind,
      userOffsetLocked: userOffsetLocked ?? this.userOffsetLocked,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is LyricOffsetSnapshot &&
        other.trackOffsetMillis == trackOffsetMillis &&
        other.albumOffsetMillis == albumOffsetMillis &&
        other.routeOffsetMillis == routeOffsetMillis &&
        other.activeRouteKind == activeRouteKind &&
        other.userOffsetLocked == userOffsetLocked;
  }

  @override
  int get hashCode => Object.hash(
    trackOffsetMillis,
    albumOffsetMillis,
    routeOffsetMillis,
    activeRouteKind,
    userOffsetLocked,
  );
}

/// 歌词三级偏移解析与格式化工具（纯领域无状态算法）。
abstract final class LyricOffsetResolver {
  static final RegExp _bluetoothRouteRegex = RegExp(
    r'(?:bluetooth|a2dp|btaudio|bthhf|hands[\s_-]*free|airpods|freebuds|galaxy[\s_-]*buds|pixel[\s_-]*buds|wf-\d|wh-\d|\bbt[_\s-]|sco\b)',
    caseSensitive: false,
  );

  /// 根据当前音频输出设备名称与外设指纹归类输出路由（蓝牙 vs 有线/扬声器）。
  static LyricAudioRouteKind classifyAudioRoute({
    String? deviceName,
    String? deviceFingerprint,
  }) {
    final combined = '${deviceName ?? ''} ${deviceFingerprint ?? ''}'.trim();
    if (combined.isEmpty) return LyricAudioRouteKind.wired;
    return _bluetoothRouteRegex.hasMatch(combined)
        ? LyricAudioRouteKind.bluetooth
        : LyricAudioRouteKind.wired;
  }

  /// 将毫秒偏移格式化为面向用户的简明秒数文本（如 `+0.3s`、`-0.5s`、`0.0s`）。
  static String formatOffsetSeconds(int offsetMillis) {
    if (offsetMillis == 0) return '0.0s';
    final seconds = offsetMillis / 1000.0;
    final sign = seconds > 0 ? '+' : '';
    final fixed = seconds.abs() * 10 == (seconds.abs() * 10).roundToDouble()
        ? seconds.toStringAsFixed(1)
        : seconds.toStringAsFixed(2);
    return '$sign${fixed}s';
  }
}
