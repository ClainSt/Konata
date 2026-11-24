import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

/// 扫图画廊展示模式。
enum ScanGalleryMode {
  /// 默认：整齐网格（统一 `3:4` 光学画框 + `BoxFit.contain` 无裁切，远程冷态零抖动）。
  uniformFrame('保序画框'),

  /// 可选：自适应等高瀑布流（利用已持久化或帧头探测自然宽高比铺排，锁定已滚过行防跳动）。
  justified('等高流');

  const ScanGalleryMode(this.label);

  /// 简体中文分段切换文案。
  final String label;
}

/// 扫图画廊 3 档视图密度。
enum ScanGalleryDensity {
  /// 紧凑高密度预览。
  compact('紧凑', 144.0, 174.0),

  /// 标准均衡预览。
  standard('标准', 198.0, 232.0),

  /// 大图细节预览。
  large('大图', 274.0, 312.0);

  const ScanGalleryDensity(
    this.label,
    this.uniformMaxExtent,
    this.justifiedTargetHeight,
  );

  /// 简体中文密度标签。
  final String label;

  /// 整齐网格模式下的单列最大宽度。
  final double uniformMaxExtent;

  /// 自适应瀑布流模式下的目标行高。
  final double justifiedTargetHeight;
}

/// 扫图画廊用户偏好设置快照（存入 `ScopedPrefsStore`，支持跨设备便携同步）。
final class ScanGalleryPrefs {
  /// 创建画廊偏好设置快照。
  const ScanGalleryPrefs({
    this.mode = ScanGalleryMode.uniformFrame,
    this.density = ScanGalleryDensity.standard,
  });

  /// 默认偏好常量。
  static const ScanGalleryPrefs defaults = ScanGalleryPrefs();

  /// 画廊排布模式（整齐网格 / 等高瀑布流）。
  final ScanGalleryMode mode;

  /// 视图密度档位（紧凑 / 标准 / 大图）。
  final ScanGalleryDensity density;

  /// 复制并修改指定偏好字段。
  ScanGalleryPrefs copyWith({
    ScanGalleryMode? mode,
    ScanGalleryDensity? density,
  }) {
    return ScanGalleryPrefs(
      mode: mode ?? this.mode,
      density: density ?? this.density,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ScanGalleryPrefs &&
        other.mode == mode &&
        other.density == density;
  }

  @override
  int get hashCode => Object.hash(mode, density);
}

/// 扫图画廊分命名空间强类型配置切片描述。
final TypedPrefsSlice<ScanGalleryPrefs> scanGalleryPrefsSlice =
    TypedPrefsSlice<ScanGalleryPrefs>(
      namespace: 'feature_scan_viewer.gallery',
      schemaVersion: 1,
      syncPolicy: SyncPolicy.portable,
      defaultValue: ScanGalleryPrefs.defaults,
      encode: (prefs) => <String, Object?>{
        'mode': prefs.mode.name,
        'density': prefs.density.name,
      },
      decode: (json, _) {
        final modeName = json['mode'] as String?;
        final densityName = json['density'] as String?;
        final mode = ScanGalleryMode.values
            .where((item) => item.name == modeName)
            .firstOrNull;
        final density = ScanGalleryDensity.values
            .where((item) => item.name == densityName)
            .firstOrNull;
        return ScanGalleryPrefs(
          mode: mode ?? ScanGalleryMode.uniformFrame,
          density: density ?? ScanGalleryDensity.standard,
        );
      },
    );
