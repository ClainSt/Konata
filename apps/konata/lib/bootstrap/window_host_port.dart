import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';

/// 平台无关的桌面无框窗口宿主端口（隔离 `flutter_acrylic` / `window_manager` 以保障 Android 零桌面依赖）。
abstract interface class KonataDesktopWindowHostPort {
  /// 将应用明暗主题与窗口材质同步至桌面合成器。
  Future<void> applyMaterial({
    required ThemeMode themeMode,
    required Brightness platformBrightness,
    required KonataWindowMaterial material,
    bool force = false,
  });

  /// 重新隐藏系统原生标题栏三键，防止与无框自绘三键重叠。
  Future<void> hideWindowControls();

  /// 绑定原生窗口实时拖拽缩放通知通道（驱动毛玻璃降级防卡顿），返回解绑释放回调。
  void Function() bindLiveResizeChannel(ValueNotifier<bool> resizingNotifier);

  /// 构建无框窗口控制三键（最小化 / 最大化还原 / 关闭）。
  Widget buildWindowControls({
    bool forceLightIcons = false,
    bool showGlassPill = false,
  });

  /// 包裹桌面顶栏可拖拽移动与双击最大化区域。
  Widget buildDragToMoveArea({required Widget child});
}
