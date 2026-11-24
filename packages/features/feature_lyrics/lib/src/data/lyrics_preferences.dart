import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

import '../domain/lyric_offset_resolver.dart';

/// 歌词引擎与全局播放偏好实体（持久化于分层配置切片命名空间 `lyrics`）。
class LyricsPreferences {
  /// 默认构造函数（内置开放与开源歌词源默认启用，非官方来源默认关闭，双语翻译默认开启）。
  const LyricsPreferences({
    this.neteaseEnabled = true,
    this.amllEnabled = true,
    this.lrclibEnabled = true,
    this.qqEnabled = false,
    this.qqDisclaimerAccepted = false,
    this.showTranslation = true,
    this.showRomaji = false,
    this.wiredOffsetMillis = 0,
    this.bluetoothOffsetMillis = 0,
  });

  /// 持久化配置命名空间标识。
  static const String prefsNamespace = 'lyrics';

  /// 是否启用网易云音乐歌词源。
  final bool neteaseEnabled;

  /// 是否启用开源逐字歌词源。
  final bool amllEnabled;

  /// 是否启用开源同步歌词源。
  final bool lrclibEnabled;

  /// 是否启用 QQ 音乐非官方歌词源（默认关闭，首次开启需确认免责声明）。
  final bool qqEnabled;

  /// 用户是否已阅读并同意非官方歌词源免责声明。
  final bool qqDisclaimerAccepted;

  /// 沉浸歌词舞台是否展示双语翻译副行。
  final bool showTranslation;

  /// 沉浸歌词舞台是否展示罗马音注音副行。
  final bool showRomaji;

  /// 有线与扬声器输出路由的全局歌词偏移（毫秒，正值歌词提前）。
  final int wiredOffsetMillis;

  /// 蓝牙输出路由的全局歌词偏移（毫秒，用于补偿蓝牙音频缓冲延迟）。
  final int bluetoothOffsetMillis;

  /// 查询指定输出路由当前生效的全局补偿延迟（毫秒）。
  int offsetForRoute(LyricAudioRouteKind routeKind) {
    return switch (routeKind) {
      LyricAudioRouteKind.wired => wiredOffsetMillis,
      LyricAudioRouteKind.bluetooth => bluetoothOffsetMillis,
    };
  }

  /// 复制并按需替换局部设置。
  LyricsPreferences copyWith({
    bool? neteaseEnabled,
    bool? amllEnabled,
    bool? lrclibEnabled,
    bool? qqEnabled,
    bool? qqDisclaimerAccepted,
    bool? showTranslation,
    bool? showRomaji,
    int? wiredOffsetMillis,
    int? bluetoothOffsetMillis,
  }) {
    return LyricsPreferences(
      neteaseEnabled: neteaseEnabled ?? this.neteaseEnabled,
      amllEnabled: amllEnabled ?? this.amllEnabled,
      lrclibEnabled: lrclibEnabled ?? this.lrclibEnabled,
      qqEnabled: qqEnabled ?? this.qqEnabled,
      qqDisclaimerAccepted: qqDisclaimerAccepted ?? this.qqDisclaimerAccepted,
      showTranslation: showTranslation ?? this.showTranslation,
      showRomaji: showRomaji ?? this.showRomaji,
      wiredOffsetMillis: wiredOffsetMillis ?? this.wiredOffsetMillis,
      bluetoothOffsetMillis:
          bluetoothOffsetMillis ?? this.bluetoothOffsetMillis,
    );
  }

  /// 持久化分命名空间偏好切片描述（参与跨设备配置同步）。
  static const TypedPrefsSlice<LyricsPreferences> prefsSlice =
      TypedPrefsSlice<LyricsPreferences>(
        namespace: prefsNamespace,
        schemaVersion: 1,
        syncPolicy: SyncPolicy.portable,
        defaultValue: LyricsPreferences(),
        encode: encodeJson,
        decode: decodeJson,
      );

  /// 序列化为结构化字典。
  static Map<String, Object?> encodeJson(LyricsPreferences value) =>
      <String, Object?>{
        'neteaseEnabled': value.neteaseEnabled,
        'amllEnabled': value.amllEnabled,
        'lrclibEnabled': value.lrclibEnabled,
        'qqEnabled': value.qqEnabled,
        'qqDisclaimerAccepted': value.qqDisclaimerAccepted,
        'showTranslation': value.showTranslation,
        'showRomaji': value.showRomaji,
        'wiredOffsetMillis': LyricOffsetSnapshot.clampRoute(
          value.wiredOffsetMillis,
        ),
        'bluetoothOffsetMillis': LyricOffsetSnapshot.clampRoute(
          value.bluetoothOffsetMillis,
        ),
      };

  /// 从字典反序列化（对路由偏移自动钳制至安全边界）。
  static LyricsPreferences decodeJson(
    Map<String, Object?> json,
    int storedSchemaVersion,
  ) {
    final wiredRaw = (json['wiredOffsetMillis'] as num?)?.toInt() ?? 0;
    final bluetoothRaw = (json['bluetoothOffsetMillis'] as num?)?.toInt() ?? 0;
    return LyricsPreferences(
      neteaseEnabled: json['neteaseEnabled'] as bool? ?? true,
      amllEnabled: json['amllEnabled'] as bool? ?? true,
      lrclibEnabled: json['lrclibEnabled'] as bool? ?? true,
      qqEnabled: json['qqEnabled'] as bool? ?? false,
      qqDisclaimerAccepted: json['qqDisclaimerAccepted'] as bool? ?? false,
      showTranslation: json['showTranslation'] as bool? ?? true,
      showRomaji: json['showRomaji'] as bool? ?? false,
      wiredOffsetMillis: LyricOffsetSnapshot.clampRoute(wiredRaw),
      bluetoothOffsetMillis: LyricOffsetSnapshot.clampRoute(bluetoothRaw),
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is LyricsPreferences &&
        other.neteaseEnabled == neteaseEnabled &&
        other.amllEnabled == amllEnabled &&
        other.lrclibEnabled == lrclibEnabled &&
        other.qqEnabled == qqEnabled &&
        other.qqDisclaimerAccepted == qqDisclaimerAccepted &&
        other.showTranslation == showTranslation &&
        other.showRomaji == showRomaji &&
        other.wiredOffsetMillis == wiredOffsetMillis &&
        other.bluetoothOffsetMillis == bluetoothOffsetMillis;
  }

  @override
  int get hashCode => Object.hash(
    neteaseEnabled,
    amllEnabled,
    lrclibEnabled,
    qqEnabled,
    qqDisclaimerAccepted,
    showTranslation,
    showRomaji,
    wiredOffsetMillis,
    bluetoothOffsetMillis,
  );
}

/// 歌词设置偏好自治存储访问器（零状态框架依赖）。
final class LyricsPreferencesStore {
  /// 使用分命名空间配置存储器构造访问器。
  const LyricsPreferencesStore(
    this._scopedPrefs, {
    this._eventBus,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final ScopedPrefsStore _scopedPrefs;
  final DomainEventBus? _eventBus;
  final DateTime Function() _now;

  /// 读取当前歌词设置偏好。
  LyricsPreferences read() => _scopedPrefs.read(LyricsPreferences.prefsSlice);

  /// 响应式监听歌词设置偏好变化流。
  Stream<LyricsPreferences> watch() =>
      _scopedPrefs.watch(LyricsPreferences.prefsSlice);

  /// 持久化更新歌词设置偏好并广播低频配置变更事件。
  void write(LyricsPreferences next) {
    _scopedPrefs.write(LyricsPreferences.prefsSlice, next);
    _eventBus?.publish(
      PrefsSliceChangedEvent(
        namespace: LyricsPreferences.prefsNamespace,
        occurredAtMs: _now().toUtc().millisecondsSinceEpoch,
      ),
    );
  }

  /// 切换网易云歌词源启用状态。
  void setNeteaseEnabled(bool enabled) =>
      write(read().copyWith(neteaseEnabled: enabled));

  /// 切换逐字歌词开源库启用状态。
  void setAmllEnabled(bool enabled) =>
      write(read().copyWith(amllEnabled: enabled));

  /// 切换开源同步歌词源启用状态。
  void setLrclibEnabled(bool enabled) =>
      write(read().copyWith(lrclibEnabled: enabled));

  /// 确认免责声明并开启非官方歌词源。
  void acceptQqDisclaimerAndEnable() =>
      write(read().copyWith(qqDisclaimerAccepted: true, qqEnabled: true));

  /// 切换非官方歌词源启用状态（若已拒绝免责声明则不允许直接启用）。
  void setQqEnabled(bool enabled) {
    final current = read();
    if (enabled && !current.qqDisclaimerAccepted) return;
    write(current.copyWith(qqEnabled: enabled));
  }

  /// 切换双语翻译显示开关。
  void setShowTranslation(bool enabled) =>
      write(read().copyWith(showTranslation: enabled));

  /// 切换罗马音注音显示开关。
  void setShowRomaji(bool enabled) =>
      write(read().copyWith(showRomaji: enabled));

  /// 设置指定音频输出路由的全局歌词偏移（毫秒）。
  void setRouteOffsetMillis(LyricAudioRouteKind routeKind, int offsetMillis) {
    final clamped = LyricOffsetSnapshot.clampRoute(offsetMillis);
    final current = read();
    final next = switch (routeKind) {
      LyricAudioRouteKind.wired => current.copyWith(wiredOffsetMillis: clamped),
      LyricAudioRouteKind.bluetooth => current.copyWith(
        bluetoothOffsetMillis: clamped,
      ),
    };
    write(next);
  }
}
