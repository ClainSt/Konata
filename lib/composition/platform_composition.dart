import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/providers/library_providers.dart';
import '../application/providers/theme_providers.dart';
import '../domain/models/relay_target_descriptor.dart';
import '../domain/playback/cue_and_lrc_parser.dart';
import '../domain/repositories/desktop_relay_service.dart';
import '../infrastructure/players/konata_video_texture_bridge.dart';
import '../infrastructure/players/mpv_quality_profile.dart';

/// 桌面顶栏导航构建签名（仅 Windows 组装根提供真实实现，Android 组装根为 `null`）。
typedef DesktopTopNavBarBuilder =
    Widget Function({
      required KonataNavSection activeSection,
      required ValueChanged<KonataNavSection> onSectionChanged,
      required String searchQuery,
      required ValueChanged<String> onSearchChanged,
      required FocusNode searchFocusNode,
      required bool searchExpanded,
      required ValueChanged<bool> onSearchExpandedChanged,
      required VoidCallback onToggleTheme,
    });

/// 跨平台窗口宿主抽象接口（隔离桌面窗口与材质依赖，确保 Android 零桌面依赖）。
abstract interface class KonataWindowHost {
  /// 同步应用亮暗主题与系统窗口材质（Android 端为空操作）。
  Future<void> applyMaterial({
    required ThemeMode themeMode,
    required Brightness platformBrightness,
    required KonataWindowMaterial material,
    bool force = false,
  });

  /// 隐藏系统原生标题栏按钮以防重复显示。
  Future<void> hideWindowControls();

  /// 查询当前窗口是否处于桌面全屏状态。
  Future<bool> isFullScreen();

  /// 切换桌面窗口全屏状态。
  Future<void> setFullScreen(bool fullScreen);

  /// 触发桌面窗口拖拽移动。
  Future<void> startDragging();

  /// 切换桌面窗口最大化与还原状态。
  Future<void> toggleMaximize();

  /// 构建桌面右上角窗口控制按钮组（Android 返回空占位）。
  Widget buildWindowControls({
    bool forceLightIcons = false,
    bool showGlassPill = false,
  });

  /// 包裹可拖拽移动窗口区域（Android 直接透传子节点）。
  Widget buildDragToMoveArea({required Widget child});
}

/// Android 与无窗口测试环境使用的零依赖空窗口宿主实现。
class NoopKonataWindowHost implements KonataWindowHost {
  /// 创建无操作窗口宿主。
  const NoopKonataWindowHost();

  @override
  Future<void> applyMaterial({
    required ThemeMode themeMode,
    required Brightness platformBrightness,
    required KonataWindowMaterial material,
    bool force = false,
  }) async {}

  @override
  Future<void> hideWindowControls() async {}

  @override
  Future<bool> isFullScreen() async => false;

  @override
  Future<void> setFullScreen(bool fullScreen) async {}

  @override
  Future<void> startDragging() async {}

  @override
  Future<void> toggleMaximize() async {}

  @override
  Widget buildWindowControls({
    bool forceLightIcons = false,
    bool showGlassPill = false,
  }) => const SizedBox.shrink();

  @override
  Widget buildDragToMoveArea({required Widget child}) => child;
}

/// 当前平台窗口宿主 Provider（Android 保持空实现，Windows 由组装根覆写）。
final konataWindowHostProvider = Provider<KonataWindowHost>((ref) {
  return const NoopKonataWindowHost();
});

/// 桌面视频渲染桥工厂 Provider（Android 保持返回 `null`，Windows 由组装根覆写）。
final konataVideoBridgeFactoryProvider =
    Provider<KonataVideoTextureBridge? Function()>((ref) {
      return () => null;
    });

/// 桌面 `libmpv` 驱动参数委托 Provider（Android 保持 `null`，Windows 组装根覆写）。
final mpvPlatformProfileDelegateProvider =
    Provider<MpvPlatformProfileDelegate?>((ref) => null);

/// 桌面外部接力网关 Provider（Android 保持 `null`，Windows 组装根覆写）。
final desktopRelayGatewayProvider = Provider<DesktopRelayGateway?>(
  (ref) => null,
);

/// 已配置的桌面视频接力目标列表 Provider（Android 恒返回空列表）。
final desktopVideoRelayTargetsProvider =
    FutureProvider<List<RelayTargetDescriptor>>((ref) async {
      final gateway = ref.watch(desktopRelayGatewayProvider);
      if (gateway == null) return const [];
      return gateway.listVideoTargets();
    });

/// 桌面独占「外部调用」设置面板构建器 Provider（Android 为 `null` 彻底剔除导入）。
final desktopExternalToolsPanelBuilderProvider = Provider<WidgetBuilder?>(
  (ref) => null,
);

/// 桌面顶栏导航构建器 Provider（Android 为 `null` 彻底剔除导入）。
final desktopTopNavBarBuilderProvider = Provider<DesktopTopNavBarBuilder?>(
  (ref) => null,
);

/// 可选传统代码页平台解码器 Provider（Windows 组装根注入，Android 走纯 Dart 解码链路）。
final legacyCodePageDecoderProvider = Provider<LegacyCodePageDecoder?>(
  (ref) => null,
);

/// 平台硬件解码设置说明文案 Provider（Android 默认 MediaCodec，桌面由组装根覆写）。
final platformHwdecSubtitleProvider = Provider<String>(
  (ref) => '自动启用 MediaCodec 硬件加速，遇异常源自动软解兜底',
);

/// 平台音频独占直通开关标题 Provider（桌面组装根覆写具体系统接口名称）。
final platformExclusiveAudioTitleProvider = Provider<String>(
  (ref) => '音频独占直通模式',
);

/// 平台音频独占直通侧栏开关标题 Provider（桌面组装根覆写具体系统接口名称）。
final platformExclusiveAudioSheetTitleProvider = Provider<String>(
  (ref) => '音频独占直通',
);

/// 平台比特流源码透传标题 Provider（桌面组装根覆写具体接口名称）。
final platformBitstreamTitleProvider = Provider<String>(
  (ref) => '比特流源码透传',
);
