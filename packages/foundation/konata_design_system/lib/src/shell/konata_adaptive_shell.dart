import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../tokens/konata_adaptive_tokens.dart';
import '../tokens/konata_palette.dart';
import '../tokens/konata_playback_tokens.dart';
import '../tokens/konata_theme.dart';
import '../widgets/konata_ambient_backdrop.dart';
import '../widgets/konata_keep_alive_tab_switcher.dart';
import 'adaptive_capsule_layout.dart';
import 'capsule_navigation.dart';
import 'konata_bottom_clearance_scope.dart';
import 'konata_top_nav_bar.dart';

/// Konata v3 三端同源自适应主壳层（严格 0 Riverpod、0 业务依赖）。
///
/// - Windows 桌面端：无框顶栏纯文字导航 + 可选流光氛围画布 + 透明底穿透原生材质；
/// - Android 平板（`shortestSide >= 600dp`）：左侧安全区边缘纵向居中悬浮胶囊；
/// - Android 手机（`shortestSide < 600dp`）：底部安全区上方横向居中悬浮胶囊；
/// - 统一向子树注入 [KonataBottomClearanceScope] 与懒加载保活切页容器 [KonataKeepAliveTabSwitcher]。
class KonataAdaptiveShell extends StatefulWidget {
  /// 创建三端自适应主壳层。
  const KonataAdaptiveShell({
    super.key,
    required this.navItems,
    required this.pages,
    required this.selectedIndex,
    required this.onSelectedIndexChanged,
    required this.onToggleTheme,
    this.searchQuery = '',
    this.onSearchChanged,
    this.searchPageIndex = 0,
    this.navigationHidden = false,
    this.desktopAmbientBackdropEnabled = false,
    this.miniKind = FloatingMiniPlayerKind.none,
    this.normalizedMiniAnchor,
    this.visualState = FloatingMiniVisualState.collapsed,
    this.edgeSide = FloatingMiniEdgeSide.right,
    this.desktopBottomClearance = 0.0,
    this.windowDragBackground,
    this.trailingWindowControls,
  });

  /// 顶层导航项列表（与 [pages] 一一对应）。
  final List<KonataNavItem> navItems;

  /// 主页面子树列表（通过 [KonataKeepAliveTabSwitcher] 懒加载保活）。
  final List<Widget> pages;

  /// 当前选中的主导航下标。
  final int selectedIndex;

  /// 导航切换回调。
  final ValueChanged<int> onSelectedIndexChanged;

  /// 桌面端顶栏切换明暗主题回调。
  final VoidCallback onToggleTheme;

  /// 桌面顶栏当前搜索词。
  final String searchQuery;

  /// 桌面顶栏搜索词变更回调。
  final ValueChanged<String>? onSearchChanged;

  /// 允许展示桌面顶栏搜索框的页面下标（默认 `0` 对应媒体库）。
  final int searchPageIndex;

  /// 移动端是否隐藏主导航胶囊（如进入二级设置页或全屏播放时）。
  final bool navigationHidden;

  /// Windows 桌面端是否叠加轻柔流光氛围画布。
  final bool desktopAmbientBackdropEnabled;

  /// 当前活跃悬浮小窗类型（用于计算移动端安全避让与手机并排协同）。
  final FloatingMiniPlayerKind miniKind;

  /// 悬浮小窗归一化停靠锚点。
  final Offset? normalizedMiniAnchor;

  /// 悬浮小窗展开形态。
  final FloatingMiniVisualState visualState;

  /// 悬浮小窗贴边方向。
  final FloatingMiniEdgeSide edgeSide;

  /// 桌面端可选附加底部避让（默认 `0.0`）。
  final double desktopBottomClearance;

  /// 桌面端顶栏底层拖拽区域槽位（由 Windows 宿主壳注入）。
  final Widget? windowDragBackground;

  /// 桌面端顶栏右侧窗口控制三键槽位（由 Windows 宿主壳注入）。
  final Widget? trailingWindowControls;

  @override
  State<KonataAdaptiveShell> createState() => _KonataAdaptiveShellState();
}

class _KonataAdaptiveShellState extends State<KonataAdaptiveShell> {
  final FocusNode _searchFocusNode = FocusNode();
  bool _searchExpanded = false;

  @override
  void dispose() {
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _activateSearch() {
    if (widget.onSearchChanged == null) return;
    if (widget.selectedIndex != widget.searchPageIndex &&
        widget.searchPageIndex < widget.navItems.length) {
      widget.onSelectedIndexChanged(widget.searchPageIndex);
    }
    setState(() => _searchExpanded = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _searchFocusNode.requestFocus();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final shortcuts = <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.keyK, control: true):
          _activateSearch,
    };

    if (KonataAdaptiveTokens.isAndroid) {
      final geometry = AdaptiveCapsuleLayout(
        size: MediaQuery.sizeOf(context),
        safe: AdaptiveCapsuleLayout.effectiveSafeInsetsOf(context),
        android: true,
        navigationItemCount: widget.navItems.length,
        navigationVisible: !widget.navigationHidden,
        miniKind: widget.miniKind,
        normalizedMiniAnchor: widget.normalizedMiniAnchor,
        visualState: widget.visualState,
        edgeSide: widget.edgeSide,
      );
      final canvasColor = context.palette.isDark
          ? KonataTheme.cinemaObsidian
          : KonataTheme.themePreviewLightCanvas;
      return CallbackShortcuts(
        bindings: shortcuts,
        child: KonataBottomClearanceScope(
          bottomClearance: geometry.bottomClearance,
          child: Scaffold(
            backgroundColor: canvasColor,
            body: Stack(
              children: <Widget>[
                const Positioned.fill(
                  child: KonataAmbientShellBackdrop(opaqueBase: true),
                ),
                Positioned.fill(
                  left: geometry.leftClearance,
                  child: RepaintBoundary(
                    child: SafeArea(
                      bottom: false,
                      child: KonataKeepAliveTabSwitcher(
                        activeIndex: widget.selectedIndex,
                        scrimFadeColor: canvasColor,
                        idleEvictAfter:
                            KonataPlaybackTokens.backgroundTabEvictIdleDuration,
                        children: widget.pages,
                      ),
                    ),
                  ),
                ),
                if (!widget.navigationHidden)
                  AnimatedPositioned.fromRect(
                    duration: KonataTheme.motionMedium,
                    curve: Curves.easeOutCubic,
                    rect: geometry.navigationRect,
                    child: RepaintBoundary(
                      child: CapsuleNavigation(
                        vertical: geometry.verticalNavigation,
                        items: widget.navItems,
                        selectedIndex: widget.selectedIndex,
                        onSelected: widget.onSelectedIndexChanged,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    }

    return CallbackShortcuts(
      bindings: shortcuts,
      child: KonataBottomClearanceScope(
        bottomClearance: widget.desktopBottomClearance,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: Stack(
            children: <Widget>[
              if (widget.desktopAmbientBackdropEnabled)
                const Positioned.fill(
                  child: KonataAmbientShellBackdrop(
                    opaqueBase: false,
                    intensity: 0.62,
                  ),
                ),
              Column(
                children: <Widget>[
                  RepaintBoundary(
                    child: KonataTopNavBar(
                      items: widget.navItems,
                      selectedIndex: widget.selectedIndex,
                      onSelectedIndexChanged: widget.onSelectedIndexChanged,
                      showSearch:
                          widget.onSearchChanged != null &&
                          widget.selectedIndex == widget.searchPageIndex,
                      searchQuery: widget.searchQuery,
                      onSearchChanged: widget.onSearchChanged ?? (_) {},
                      searchFocusNode: _searchFocusNode,
                      searchExpanded: _searchExpanded,
                      onSearchExpandedChanged: (expanded) {
                        setState(() => _searchExpanded = expanded);
                      },
                      onToggleTheme: widget.onToggleTheme,
                      windowDragBackground: widget.windowDragBackground,
                      trailingWindowControls: widget.trailingWindowControls,
                    ),
                  ),
                  Expanded(
                    child: ClipRect(
                      child: KonataKeepAliveTabSwitcher(
                        activeIndex: widget.selectedIndex,
                        idleEvictAfter:
                            KonataPlaybackTokens.backgroundTabEvictIdleDuration,
                        children: widget.pages,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
