import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/theme_providers.dart';

/// Windows 11 原生 DWM 窗口材质控制器（实例由 Riverpod 托管，消除全局静态可变状态）。
///
/// 负责将应用的亮/暗主题模式与用户所选材质（Acrylic / Mica / Tabbed）
/// 实时同步至 Win32 DWM 合成层，实现透明桌面壁纸穿透光影。
class WindowMaterialController {
  /// 暗色模式下的亚克力半透明叠色（深曜石底色，透出桌面光影）。
  static const Color darkAcrylicTint = Color(0xB80E1015);

  /// 亮色模式下的亚克力半透明叠色（柔和画册白，透出桌面光影）。
  static const Color lightAcrylicTint = Color(0xC4F4F5F8);

  /// 判断当前实际生效的是否为暗色模式。
  static bool resolveIsDark(
    ThemeMode mode,
    Brightness platformBrightness,
  ) {
    return switch (mode) {
      ThemeMode.dark => true,
      ThemeMode.light => false,
      ThemeMode.system => platformBrightness == Brightness.dark,
    };
  }

  bool? _lastIsDark;
  KonataWindowMaterial? _lastMaterial;

  /// 应用 Windows DWM 窗口材质与明暗效果。
  Future<void> apply({
    required ThemeMode themeMode,
    required Brightness platformBrightness,
    required KonataWindowMaterial material,
    bool force = false,
  }) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) {
      return;
    }
    final isDark = resolveIsDark(themeMode, platformBrightness);
    if (!force && _lastIsDark == isDark && _lastMaterial == material) {
      return;
    }
    _lastIsDark = isDark;
    _lastMaterial = material;
    try {
      switch (material) {
        case KonataWindowMaterial.acrylic:
          await Window.setEffect(
            effect: WindowEffect.acrylic,
            color: isDark ? darkAcrylicTint : lightAcrylicTint,
            dark: isDark,
          );
        case KonataWindowMaterial.mica:
          await Window.setEffect(
            effect: WindowEffect.mica,
            dark: isDark,
          );
        case KonataWindowMaterial.tabbed:
          await Window.setEffect(
            effect: WindowEffect.tabbed,
            dark: isDark,
          );
      }
      // 每次应用或切换 DWM 材质后重新隐藏 Win32 原生标题栏控制按钮，防止与 Flutter 控制键重叠
      await Window.hideWindowControls();
    } catch (e) {
      debugPrint('应用 Windows DWM 窗口材质忽略：$e');
    }
  }
}

/// Windows 窗口材质控制器 Provider。
final windowMaterialControllerProvider = Provider<WindowMaterialController>(
  (ref) => WindowMaterialController(),
);
