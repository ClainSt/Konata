import 'dart:math' as math;
import '../l10n/strings.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import '../core/app_theme.dart';

class AppHeader extends StatelessWidget {
  const AppHeader({
    super.key,
    required this.showSources,
    this.settingsSelected = false,
    this.mobile,
    required this.onNavigate,
    required this.onSettings,
    this.playbackTitle,
    this.onPlaybackBack,
  });
  final bool showSources;
  final bool settingsSelected;
  final bool? mobile;
  final ValueChanged<bool> onNavigate;
  final VoidCallback onSettings;
  final String? playbackTitle;
  final VoidCallback? onPlaybackBack;
  static bool get desktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  @override
  Widget build(BuildContext context) {
    if (mobile ?? !desktop) {
      return Material(
        child: SafeArea(
          top: false,
          child: NavigationBar(
            selectedIndex: settingsSelected
                ? 2
                : showSources
                ? 1
                : 0,
            onDestinationSelected: (index) {
              if (index == 2) {
                onSettings();
              } else {
                onNavigate(index == 1);
              }
            },
            destinations: [
              NavigationDestination(
                key: ValueKey('nav-library'),
                icon: Icon(Icons.video_library_outlined),
                label: context.l10n.library,
              ),
              NavigationDestination(
                key: ValueKey('nav-sources'),
                icon: Icon(Icons.storage_outlined),
                label: context.l10n.sources,
              ),
              NavigationDestination(
                key: ValueKey('nav-settings'),
                icon: Icon(Icons.settings_outlined),
                label: context.l10n.settings,
              ),
            ],
          ),
        ),
      );
    }
    final dark = Theme.of(context).brightness == Brightness.dark;
    return LayoutBuilder(
      builder: (context, bounds) {
        final entries = [
          (false, context.l10n.library),
          (true, context.l10n.sources),
        ];
        final tabStyle = Theme.of(context).textTheme.bodyMedium!.copyWith(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          height: 1.25,
          letterSpacing: 0,
        );
        double tabWidth(String label) {
          final painter = TextPainter(
            text: TextSpan(text: label, style: tabStyle),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
          )..layout();
          final width = math.max(104.0, painter.width.ceilToDouble() + 32);
          painter.dispose();
          return width;
        }

        final actionWidth =
            96.0 +
            (desktop && bounds.maxWidth >= 600 ? 144 : 0) +
            (!desktop ? 8 : 0);
        final navWidth = math.min(
          entries.fold<double>(0, (sum, entry) => sum + tabWidth(entry.$2)),
          math.max(0.0, bounds.maxWidth - actionWidth - 8),
        );
        return Material(
          color: Theme.of(context).scaffoldBackgroundColor,
          child: SafeArea(
            bottom: false,
            child: SizedBox(
              height: 72,
              child: Row(
                children: [
                  const SizedBox(width: 8),
                  if (playbackTitle != null)
                    Expanded(
                      child: Row(
                        children: [
                          IconButton(
                            key: const ValueKey('playback-header-back'),
                            onPressed: onPlaybackBack,
                            icon: const Icon(Icons.arrow_back),
                          ),
                          Expanded(
                            child: Tooltip(
                              message: playbackTitle!,
                              child: Text(
                                playbackTitle!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    SizedBox(
                      width: navWidth,
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            for (final entry in entries)
                              InkWell(
                                key: ValueKey(
                                  'nav-${entry.$1 ? 'sources' : 'library'}',
                                ),
                                onTap: () => onNavigate(entry.$1),
                                child: Container(
                                  width: tabWidth(entry.$2),
                                  alignment: Alignment.center,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                  ),
                                  child: Column(
                                    children: [
                                      Expanded(
                                        child: Center(
                                          child: Padding(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                            ),
                                            child: Text(
                                              entry.$2,
                                              maxLines: 1,
                                              softWrap: false,
                                              style: tabStyle.copyWith(
                                                color: showSources == entry.$1
                                                    ? Theme.of(
                                                        context,
                                                      ).colorScheme.primary
                                                    : Theme.of(context)
                                                          .colorScheme
                                                          .onSurface
                                                          .withValues(
                                                            alpha: .6,
                                                          ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                      Container(
                                        height: 3,
                                        width: 76,
                                        decoration: BoxDecoration(
                                          color: showSources == entry.$1
                                              ? Theme.of(
                                                  context,
                                                ).colorScheme.primary
                                              : Colors.transparent,
                                          borderRadius: BorderRadius.circular(
                                            3,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  if (playbackTitle == null)
                    Expanded(
                      child: desktop
                          ? const DragToMoveArea(child: SizedBox.expand())
                          : const SizedBox(),
                    ),
                  IconButton(
                    key: const ValueKey('toggle-theme'),
                    style: IconButton.styleFrom(fixedSize: const Size(48, 48)),
                    color: Theme.of(context).colorScheme.onSurface,
                    iconSize: 24,
                    tooltip: dark
                        ? context.l10n.switchLight
                        : context.l10n.switchDark,
                    icon: Icon(
                      dark
                          ? Icons.dark_mode_outlined
                          : Icons.light_mode_outlined,
                    ),
                    onPressed: () async {
                      try {
                        await AppTheme.instance.setMode(
                          dark ? ThemeMode.light : ThemeMode.dark,
                        );
                      } catch (_) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(context.l10n.themeSaveFailed),
                            ),
                          );
                        }
                      }
                    },
                  ),
                  IconButton(
                    key: const ValueKey('open-settings'),
                    style: IconButton.styleFrom(fixedSize: const Size(48, 48)),
                    tooltip: context.l10n.settings,
                    onPressed: onSettings,
                    color: Theme.of(context).colorScheme.onSurface,
                    iconSize: 24,
                    icon: const Icon(Icons.settings),
                  ),
                  if (desktop && bounds.maxWidth >= 600) const WindowActions(),
                  if (!desktop) const SizedBox(width: 8),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class PlaybackOverlayTitle extends StatelessWidget {
  const PlaybackOverlayTitle({
    super.key,
    required this.title,
    required this.draggable,
  });
  final String title;
  final bool draggable;
  @override
  Widget build(BuildContext context) {
    final label = Align(
      alignment: Alignment.centerLeft,
      child: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 16,
          shadows: [Shadow(blurRadius: 4)],
        ),
      ),
    );
    return draggable ? DragToMoveArea(child: label) : label;
  }
}

class WindowActions extends StatefulWidget {
  const WindowActions({super.key, this.color});
  final Color? color;
  @override
  State<WindowActions> createState() => _WindowActionsState();
}

class _WindowActionsState extends State<WindowActions> with WindowListener {
  bool maximized = false;
  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.isMaximized().then((value) {
      if (mounted) setState(() => maximized = value);
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() => setState(() => maximized = true);
  @override
  void onWindowUnmaximize() => setState(() => maximized = false);

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final action in [
        (
          context.l10n.minimize,
          Icons.remove,
          () async => windowManager.minimize(),
        ),
        (
          maximized ? context.l10n.restoreWindow : context.l10n.maximize,
          maximized ? Icons.filter_none : Icons.crop_square,
          () async {
            if (await windowManager.isMaximized()) {
              await windowManager.unmaximize();
            } else {
              await windowManager.maximize();
            }
          },
        ),
        (
          context.l10n.closeWindow,
          Icons.close,
          () async => windowManager.close(),
        ),
      ])
        IconButton(
          key: ValueKey('window-${action.$1}'),
          tooltip: action.$1,
          onPressed: action.$3,
          style: IconButton.styleFrom(fixedSize: const Size(48, 48)),
          color: widget.color ?? Theme.of(context).colorScheme.onSurface,
          icon: Icon(action.$2, size: 24),
        ),
    ],
  );
}
