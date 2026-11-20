import 'dart:developer' as developer;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 主题模式持久化 Key。
const String _kThemeModePrefKey = 'konata_v2_theme_mode';

/// Windows 窗口材质持久化 Key。
const String _kWindowMaterialPrefKey = 'konata_v2_window_material';

/// 流光氛围画布开关持久化 Key（桌面端默认关闭以保留系统原生 DWM 透光）。
const String _kAmbientCanvasPrefKey = 'konata_v2_ambient_canvas_enabled';

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
    } catch (error) {
      // 测试环境或首次启动读取异常时维持默认深色模式
      developer.log('可恢复异常已记录', name: 'konata.theme_providers', error: error);
    }
  }

  /// 切换并持久化指定主题模式。
  Future<void> setThemeMode(ThemeMode mode) async {
    state = mode;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kThemeModePrefKey, mode.name);
    } catch (error) {
      developer.log('可恢复异常已记录', name: 'konata.theme_providers', error: error);
    }
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
    } catch (error) {
      developer.log('可恢复异常已记录', name: 'konata.theme_providers', error: error);
    }
  }

  /// 切换并持久化窗口材质。
  Future<void> setMaterial(KonataWindowMaterial material) async {
    state = material;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kWindowMaterialPrefKey, material.name);
    } catch (error) {
      developer.log('可恢复异常已记录', name: 'konata.theme_providers', error: error);
    }
  }
}

/// 流光氛围画布开关状态管理器（控制 Windows 端是否在透明窗口叠加轻柔静态流光氛围场）。
class AmbientCanvasNotifier extends StateNotifier<bool> {
  /// 创建流光氛围画布状态管理器，默认关闭以维持原生系统透光材质。
  AmbientCanvasNotifier() : super(false) {
    _restore();
  }

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getBool(_kAmbientCanvasPrefKey);
      if (!mounted || saved == null) return;
      state = saved;
    } catch (error) {
      developer.log('可恢复异常已记录', name: 'konata.theme_providers', error: error);
    }
  }

  /// 切换并持久化流光氛围画布开关。
  Future<void> setEnabled(bool enabled) async {
    state = enabled;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kAmbientCanvasPrefKey, enabled);
    } catch (error) {
      developer.log('可恢复异常已记录', name: 'konata.theme_providers', error: error);
    }
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

/// 全局流光氛围画布开关 Provider（桌面端可选开启，Android 端壳层默认叠加轻柔静态流光氛围）。
final ambientCanvasEnabledProvider =
    StateNotifierProvider<AmbientCanvasNotifier, bool>((ref) {
      return AmbientCanvasNotifier();
    });
