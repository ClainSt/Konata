import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 主题模式持久化 Key。
const String _kThemeModePrefKey = 'konata_v2_theme_mode';

/// Windows 窗口材质持久化 Key。
const String _kWindowMaterialPrefKey = 'konata_v2_window_material';

/// Windows 11 原生 DWM 窗口材质类型。
enum KonataWindowMaterial {
  /// 亚克力模糊（高透光率，实时呈现壁纸色彩与光影折射，默认推荐）。
  acrylic('亚克力 (Acrylic)', '高透光模糊，实时折射桌面壁纸光影'),

  /// 云母材质（沉稳融合系统壁纸主色调）。
  mica('云母 (Mica)', '柔和融合系统壁纸主色，视觉更沉稳'),

  /// 云母 Tabbed 变体（高对比云母材质）。
  tabbed('云母变体 (Tabbed)', '高对比度云母背景变体');

  const KonataWindowMaterial(this.label, this.subtitle);

  /// 中文显示名称。
  final String label;

  /// 中文说明副标题。
  final String subtitle;
}

/// 主题模式状态管理器（支持 暗色 / 亮色 / 跟随系统，并持久化于 SharedPreferences）。
class ThemeModeNotifier extends StateNotifier<ThemeMode> {
  /// 创建主题模式管理器，默认采用深色暗角影院风。
  ThemeModeNotifier() : super(ThemeMode.dark) {
    _restore();
  }

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_kThemeModePrefKey);
      if (!mounted || saved == null) return;
      state = switch (saved) {
        'light' => ThemeMode.light,
        'system' => ThemeMode.system,
        _ => ThemeMode.dark,
      };
    } catch (_) {
      // 测试环境或首次启动读取异常时维持默认深色模式
    }
  }

  /// 切换并持久化指定主题模式。
  Future<void> setThemeMode(ThemeMode mode) async {
    state = mode;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kThemeModePrefKey, mode.name);
    } catch (_) {}
  }

  /// 在亮色与暗色之间一键快捷切换。
  Future<void> toggleLightDark(Brightness currentPlatformBrightness) async {
    final effectiveDark =
        state == ThemeMode.dark ||
        (state == ThemeMode.system &&
            currentPlatformBrightness == Brightness.dark);
    await setThemeMode(effectiveDark ? ThemeMode.light : ThemeMode.dark);
  }
}

/// Windows 原生 DWM 窗口材质状态管理器。
class WindowMaterialNotifier extends StateNotifier<KonataWindowMaterial> {
  /// 创建窗口材质管理器，默认启用 Acrylic 亚克力材质。
  WindowMaterialNotifier() : super(KonataWindowMaterial.acrylic) {
    _restore();
  }

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_kWindowMaterialPrefKey);
      if (!mounted || saved == null) return;
      state = switch (saved) {
        'mica' => KonataWindowMaterial.mica,
        'tabbed' => KonataWindowMaterial.tabbed,
        _ => KonataWindowMaterial.acrylic,
      };
    } catch (_) {}
  }

  /// 切换并持久化窗口材质。
  Future<void> setMaterial(KonataWindowMaterial material) async {
    state = material;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kWindowMaterialPrefKey, material.name);
    } catch (_) {}
  }
}

/// 全局主题模式 Provider。
final themeModeProvider = StateNotifierProvider<ThemeModeNotifier, ThemeMode>((
  ref,
) {
  return ThemeModeNotifier();
});

/// 全局 Windows 原生窗口材质 Provider。
final windowMaterialProvider =
    StateNotifierProvider<WindowMaterialNotifier, KonataWindowMaterial>((ref) {
      return WindowMaterialNotifier();
    });
