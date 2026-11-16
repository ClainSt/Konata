import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/library_providers.dart';
import '../../application/providers/theme_providers.dart';
import '../history/playback_history_page.dart';
import '../library/library_page.dart';
import '../library/review_drawer.dart';
import '../settings/settings_page.dart';
import '../sources/sources_page.dart';
import 'top_nav_bar.dart';

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
    final reviewDrawerOpen = ref.watch(reviewDrawerOpenProvider);

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, control: true):
            _activateSearch,
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: ClipRect(
          child: Stack(
            children: [
              Column(
                children: [
                  TopNavBar(
                    activeSection: activeSection,
                    onSectionChanged: (section) {
                      ref.read(selectedNavSectionProvider.notifier).state =
                          section;
                      if (section != KonataNavSection.library &&
                          reviewDrawerOpen) {
                        ref.read(reviewDrawerOpenProvider.notifier).state =
                            false;
                      }
                    },
                    searchQuery: searchQuery,
                    onSearchChanged: (value) {
                      ref.read(librarySearchQueryProvider.notifier).state =
                          value;
                    },
                    searchFocusNode: _searchFocusNode,
                    searchExpanded: _searchExpanded,
                    onSearchExpandedChanged: (expanded) {
                      setState(() => _searchExpanded = expanded);
                    },
                    onToggleTheme: () {
                      final brightness = MediaQuery.platformBrightnessOf(
                        context,
                      );
                      ref
                          .read(themeModeProvider.notifier)
                          .toggleLightDark(brightness);
                    },
                  ),
                  Expanded(
                    child: ClipRect(
                      child: _KeepAliveSectionStack(
                        activeIndex: activeSection.index,
                      ),
                    ),
                  ),
                ],
              ),
              if (reviewDrawerOpen)
                ReviewDrawer(
                  onClose: () =>
                      ref.read(reviewDrawerOpenProvider.notifier).state = false,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 顶栏四页签「首次访问懒挂载 + 常驻保活 + 200ms GPU 图层柔和切换」容器。
class _KeepAliveSectionStack extends StatefulWidget {
  const _KeepAliveSectionStack({required this.activeIndex});

  final int activeIndex;

  @override
  State<_KeepAliveSectionStack> createState() => _KeepAliveSectionStackState();
}

class _KeepAliveSectionStackState extends State<_KeepAliveSectionStack>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animCtrl;
  late final Animation<double> _curved;
  late final List<Widget> _cachedPages;
  final List<bool> _mounted = [true, false, false, false];
  int? _leavingIndex;

  @override
  void initState() {
    super.initState();
    _mounted[widget.activeIndex] = true;
    _cachedPages = const [
      RepaintBoundary(child: LibraryPage()),
      RepaintBoundary(child: SourcesPage()),
      RepaintBoundary(child: PlaybackHistoryPage()),
      RepaintBoundary(child: SettingsPage()),
    ];
    _animCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
      value: 1.0,
    );
    _curved = CurvedAnimation(
      parent: _animCtrl,
      curve: Curves.easeOutCubic,
    );
    _animCtrl.addStatusListener((status) {
      if (status == AnimationStatus.completed && _leavingIndex != null) {
        setState(() => _leavingIndex = null);
      }
    });
  }

  @override
  void didUpdateWidget(covariant _KeepAliveSectionStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeIndex != widget.activeIndex) {
      _mounted[widget.activeIndex] = true;
      _leavingIndex = oldWidget.activeIndex;
      _animCtrl.forward(from: 0.0);
    }
  }

  @override
  void dispose() {
    _animCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        for (var i = 0; i < _cachedPages.length; i++)
          if (_mounted[i]) _buildSlot(i),
      ],
    );
  }

  Widget _buildSlot(int index) {
    final isActive = index == widget.activeIndex;
    final isLeaving = index == _leavingIndex;
    final visible = isActive || isLeaving;

    Widget content = _cachedPages[index];
    if (isActive && _leavingIndex != null) {
      content = FadeTransition(
        opacity: _curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.012),
            end: Offset.zero,
          ).animate(_curved),
          child: content,
        ),
      );
    } else if (isLeaving) {
      content = FadeTransition(
        opacity: Tween<double>(begin: 1.0, end: 0.0).animate(_curved),
        child: SlideTransition(
          position: Tween<Offset>(
            begin: Offset.zero,
            end: const Offset(0, -0.008),
          ).animate(_curved),
          child: content,
        ),
      );
    }

    return Offstage(
      offstage: !visible,
      child: IgnorePointer(
        ignoring: !isActive,
        child: TickerMode(
          enabled: isActive,
          child: content,
        ),
      ),
    );
  }
}
