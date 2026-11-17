import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/library_providers.dart';
import '../../application/playback/playback_preferences_provider.dart';
import '../../application/providers/theme_providers.dart';
import '../audio/mini_audio_bar.dart';
import '../history/playback_history_page.dart';
import '../library/library_page.dart';
import '../settings/settings_page.dart';
import '../sources/sources_page.dart';
import '../theme/konata_adaptive_tokens.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/konata_keep_alive_tab_switcher.dart';
import 'top_nav_bar.dart';
import 'adaptive_capsule_layout.dart';
import 'capsule_navigation.dart';
import 'capsule_shell_actions.dart';

/// Konata 桌面端透明流光无框主壳层（透出 Windows 11 原生 DWM Acrylic/Mica 背景）。
class DesktopShell extends ConsumerStatefulWidget {
  /// 创建桌面端主壳层。
  const DesktopShell({super.key});

  @override
  ConsumerState<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends ConsumerState<DesktopShell> {
  final FocusNode _searchFocusNode = FocusNode();
  bool _searchExpanded = false;

  @override
  void dispose() {
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
    final activeSection = ref.watch(selectedNavSectionProvider);
    final searchQuery = ref.watch(librarySearchQueryProvider);
    final bottomClearance = ref.watch(miniAudioBottomClearanceProvider);

    if (KonataAdaptiveTokens.isAndroid) {
      final hidden =
          ref.watch(capsuleNavigationHiddenProvider) ||
          ref.watch(immersiveAudioExpandedProvider) ||
          ref.watch(videoPlaybackActiveProvider);
      final geometry = AdaptiveCapsuleLayout(
        size: MediaQuery.sizeOf(context),
        safe: MediaQuery.paddingOf(context),
        android: true,
        playerVisible: bottomClearance > 0,
        navigationVisible: !hidden,
      );
      return CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyK, control: true):
              _activateSearch,
        },
        child: KonataBottomClearanceScope(
          bottomClearance: geometry.bottomClearance,
          child: Scaffold(
            backgroundColor: context.palette.isDark
                ? KonataTheme.cinemaObsidian
                : KonataTheme.themePreviewLightCanvas,
            body: Stack(
              children: [
                Positioned.fill(
                  child: Padding(
                    padding: EdgeInsets.only(left: geometry.leftClearance),
                    child: SafeArea(
                      bottom: false,
                      child: Column(
                        children: [
                          if (!hidden)
                            CapsuleShellActions(
                              query: searchQuery,
                              focusNode: _searchFocusNode,
                              onChanged: (value) {
                                ref
                                    .read(selectedNavSectionProvider.notifier)
                                    .state = KonataNavSection
                                    .library;
                                ref
                                        .read(
                                          librarySearchQueryProvider.notifier,
                                        )
                                        .state =
                                    value;
                              },
                              onToggleTheme: () => ref
                                  .read(themeModeProvider.notifier)
                                  .toggleLightDark(
                                    MediaQuery.platformBrightnessOf(context),
                                  ),
                            ),
                          Expanded(
                            child: KonataKeepAliveTabSwitcher(
                              activeIndex: activeSection.index,
                              children: const [
                                LibraryPage(),
                                SourcesPage(),
                                PlaybackHistoryPage(),
                                SettingsPage(),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (!hidden)
                  Positioned.fromRect(
                    rect: geometry.navigationRect,
                    child: CapsuleNavigation(
                      vertical: geometry.tablet,
                      selectedIndex: activeSection.index,
                      onSelected: (index) =>
                          ref.read(selectedNavSectionProvider.notifier).state =
                              KonataNavSection.values[index],
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    }
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, control: true):
            _activateSearch,
      },
      child: KonataBottomClearanceScope(
        bottomClearance: bottomClearance,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: ClipRect(
            child: Column(
              children: [
                TopNavBar(
                  activeSection: activeSection,
                  onSectionChanged: (section) {
                    ref.read(selectedNavSectionProvider.notifier).state =
                        section;
                  },
                  searchQuery: searchQuery,
                  onSearchChanged: (value) {
                    ref.read(librarySearchQueryProvider.notifier).state = value;
                  },
                  searchFocusNode: _searchFocusNode,
                  searchExpanded: _searchExpanded,
                  onSearchExpandedChanged: (expanded) {
                    setState(() => _searchExpanded = expanded);
                  },
                  onToggleTheme: () {
                    final brightness = MediaQuery.platformBrightnessOf(context);
                    ref
                        .read(themeModeProvider.notifier)
                        .toggleLightDark(brightness);
                  },
                ),
                Expanded(
                  child: ClipRect(
                    child: KonataKeepAliveTabSwitcher(
                      activeIndex: activeSection.index,
                      children: const [
                        LibraryPage(),
                        SourcesPage(),
                        PlaybackHistoryPage(),
                        SettingsPage(),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
