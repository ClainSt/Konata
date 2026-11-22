import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/playback/playback_preferences_provider.dart';
import '../../application/providers/library_providers.dart';
import '../../application/providers/scraping_providers.dart';
import '../../application/providers/theme_providers.dart';
import '../../application/scraping/ongoing_work_auto_sync.dart';
import '../../composition/platform_composition.dart';
import '../audio/mini_audio_bar.dart';
import '../history/playback_history_page.dart';
import '../library/library_page.dart';
import '../settings/settings_page.dart';
import '../sources/sources_page.dart';
import '../theme/konata_adaptive_tokens.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/konata_keep_alive_tab_switcher.dart';
import '../widgets/playback/konata_cached_artwork_backdrop.dart';
import 'adaptive_capsule_layout.dart';
import 'capsule_navigation.dart';

/// Konata 桌面端与移动端共用的自适应主壳层（切页状态隔离至叶子节点，避免整壳重建）。
class DesktopShell extends ConsumerStatefulWidget {
  /// 创建主壳层。
  const DesktopShell({super.key});

  @override
  ConsumerState<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends ConsumerState<DesktopShell>
    with WidgetsBindingObserver {
  static const List<Widget> _mainPages = <Widget>[
    LibraryPage(),
    SourcesPage(),
    PlaybackHistoryPage(),
    SettingsPage(),
  ];

  final FocusNode _searchFocusNode = FocusNode();
  bool _searchExpanded = false;
  Timer? _autoSyncStartupTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _autoSyncStartupTimer = Timer(
      OngoingWorkAutoSyncConfig.startupDelay,
      _triggerBackgroundOngoingSync,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _triggerBackgroundOngoingSync();
    }
  }

  void _triggerBackgroundOngoingSync() {
    if (!mounted) return;
    if (ref.read(videoPlaybackActiveProvider)) return;
    unawaited(
      ref.read(scrapeControllerProvider.notifier).runOngoingWorksAutoSyncIfDue(),
    );
  }

  @override
  void dispose() {
    _autoSyncStartupTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _activateSearch() {
    ref.read(selectedNavSectionProvider.notifier).state =
        KonataNavSection.library;
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
      final miniKind = ref.watch(activeFloatingMiniPlayerKindProvider);
      final miniAnchor = miniKind != FloatingMiniPlayerKind.none
          ? ref.watch(floatingMiniWindowAnchorProvider)
          : null;
      final visualState = miniKind != FloatingMiniPlayerKind.none
          ? ref.watch(floatingMiniVisualStateProvider)
          : FloatingMiniVisualState.collapsed;
      final edgeSide = miniKind != FloatingMiniPlayerKind.none
          ? ref.watch(floatingMiniEdgeSideProvider)
          : FloatingMiniEdgeSide.right;
      final hidden =
          ref.watch(capsuleNavigationHiddenProvider) ||
          ref.watch(immersiveAudioExpandedProvider) ||
          ref.watch(videoPlaybackActiveProvider);
      final geometry = AdaptiveCapsuleLayout(
        size: MediaQuery.sizeOf(context),
        safe: AdaptiveCapsuleLayout.effectiveSafeInsetsOf(context),
        android: true,
        navigationVisible: !hidden,
        miniKind: miniKind,
        normalizedMiniAnchor: miniAnchor,
        visualState: visualState,
        edgeSide: edgeSide,
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
              children: [
                const Positioned.fill(
                  child: KonataAmbientShellBackdrop(opaqueBase: true),
                ),
                Positioned.fill(
                  left: geometry.leftClearance,
                  child: RepaintBoundary(
                    child: SafeArea(
                      bottom: false,
                      child: _ShellTabBodySlot(
                        pages: _mainPages,
                        scrimFadeColor: canvasColor,
                      ),
                    ),
                  ),
                ),
                if (!hidden)
                  AnimatedPositioned.fromRect(
                    duration: KonataTheme.motionMedium,
                    curve: Curves.easeOutCubic,
                    rect: geometry.navigationRect,
                    child: RepaintBoundary(
                      child: _AndroidCapsuleNavSlot(
                        vertical: geometry.verticalNavigation,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    }

    final desktopBottomClearance = ref.watch(miniAudioBottomClearanceProvider);
    final topNavBuilder = ref.watch(desktopTopNavBarBuilderProvider);
    return CallbackShortcuts(
      bindings: shortcuts,
      child: KonataBottomClearanceScope(
        bottomClearance: desktopBottomClearance,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: Stack(
            children: [
              const Positioned.fill(child: _DesktopAmbientBackdropSlot()),
              Column(
                children: [
                  if (topNavBuilder != null)
                    RepaintBoundary(
                      child: _DesktopTopNavSlot(
                        topNavBuilder: topNavBuilder,
                        searchFocusNode: _searchFocusNode,
                        searchExpanded: _searchExpanded,
                        onSearchExpandedChanged: (expanded) {
                          setState(() => _searchExpanded = expanded);
                        },
                      ),
                    ),
                  const Expanded(
                    child: ClipRect(
                      child: _ShellTabBodySlot(pages: _mainPages),
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

/// 桌面端可选流光氛围画布叶子槽位（默认关闭，仅在用户开启时叠加轻柔透明流光，不触发壳层重建）。
class _DesktopAmbientBackdropSlot extends ConsumerWidget {
  const _DesktopAmbientBackdropSlot();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(ambientCanvasEnabledProvider);
    if (!enabled) return const SizedBox.shrink();
    return const KonataAmbientShellBackdrop(
      opaqueBase: false,
      intensity: 0.62,
    );
  }
}

/// 仅订阅主导航选中索引的页面切换槽位，切页零触发外层壳体与几何重算。
class _ShellTabBodySlot extends ConsumerWidget {
  const _ShellTabBodySlot({required this.pages, this.scrimFadeColor});

  final List<Widget> pages;
  final Color? scrimFadeColor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeIndex = ref.watch(selectedNavSectionProvider).index;
    return KonataKeepAliveTabSwitcher(
      activeIndex: activeIndex,
      scrimFadeColor: scrimFadeColor,
      children: pages,
    );
  }
}

/// Android 胶囊导航叶子订阅槽位，独立隔离于外层壳体。
class _AndroidCapsuleNavSlot extends ConsumerWidget {
  const _AndroidCapsuleNavSlot({required this.vertical});

  final bool vertical;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeIndex = ref.watch(selectedNavSectionProvider).index;
    return CapsuleNavigation(
      vertical: vertical,
      selectedIndex: activeIndex,
      onSelected: (index) =>
          ref.read(selectedNavSectionProvider.notifier).state =
              KonataNavSection.values[index],
    );
  }
}

/// Windows 顶部导航栏叶子订阅槽位，避免搜索词或切页触发壳层整树重建。
class _DesktopTopNavSlot extends ConsumerWidget {
  const _DesktopTopNavSlot({
    required this.topNavBuilder,
    required this.searchFocusNode,
    required this.searchExpanded,
    required this.onSearchExpandedChanged,
  });

  final DesktopTopNavBarBuilder topNavBuilder;
  final FocusNode searchFocusNode;
  final bool searchExpanded;
  final ValueChanged<bool> onSearchExpandedChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeSection = ref.watch(selectedNavSectionProvider);
    final searchQuery = ref.watch(librarySearchQueryProvider);
    return topNavBuilder(
      activeSection: activeSection,
      onSectionChanged: (section) {
        ref.read(selectedNavSectionProvider.notifier).state = section;
      },
      searchQuery: searchQuery,
      onSearchChanged: (value) {
        ref.read(librarySearchQueryProvider.notifier).state = value;
      },
      searchFocusNode: searchFocusNode,
      searchExpanded: searchExpanded,
      onSearchExpandedChanged: onSearchExpandedChanged,
      onToggleTheme: () {
        final brightness = MediaQuery.platformBrightnessOf(context);
        ref.read(themeModeProvider.notifier).toggleLightDark(brightness);
      },
    );
  }
}
