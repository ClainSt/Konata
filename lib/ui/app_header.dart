import '../l10n/strings.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import '../core/app_theme.dart';

enum KonataNavigationLayout { top, rail, bottom }

KonataNavigationLayout navigationLayout(Size size, {required bool desktop}) {
  if (desktop) return KonataNavigationLayout.top;
  return size.width >= 700 && size.height >= 500 && size.width > size.height
      ? KonataNavigationLayout.rail
      : KonataNavigationLayout.bottom;
}

class AppHeader extends StatelessWidget {
  const AppHeader({
    super.key,
    required this.showSources,
    this.settingsSelected = false,
    this.historySelected = false,
    this.mobile,
    this.layout,
    required this.onNavigate,
    required this.onSettings,
    this.onHistory,
    this.playbackTitle,
    this.onPlaybackBack,
  });
  final bool showSources, settingsSelected, historySelected;
  final bool? mobile;
  final KonataNavigationLayout? layout;
  final ValueChanged<bool> onNavigate;
  final VoidCallback onSettings;
  final VoidCallback? onHistory;
  final String? playbackTitle;
  final VoidCallback? onPlaybackBack;
  static bool get desktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  @override
  Widget build(BuildContext context) {
    final mode =
        layout ??
        ((mobile ?? !desktop)
            ? KonataNavigationLayout.bottom
            : KonataNavigationLayout.top);
    final bottom = mode == KonataNavigationLayout.bottom;
    final rail = mode == KonataNavigationLayout.rail;
    final colors = Theme.of(context).colorScheme;
    final selected = settingsSelected
        ? 3
        : historySelected
        ? 2
        : showSources
        ? 1
        : 0;
    final labels = [
      context.l10n.library,
      context.l10n.sources,
      context.l10n.history,
      context.l10n.settings,
    ];
    final icons = [
      Icons.videocam_outlined,
      Icons.storage_outlined,
      Icons.schedule_outlined,
      Icons.settings_outlined,
    ];
    final callbacks = <VoidCallback>[
      () => onNavigate(false),
      () => onNavigate(true),
      onHistory ?? () {},
      onSettings,
    ];
    final keys = ['library', 'sources', 'history', 'settings'];
    final scaler = MediaQuery.textScalerOf(context);
    final labelStyle = Theme.of(context).textTheme.labelMedium!.copyWith(
      fontSize: bottom ? 11 : 13,
      height: 1.5,
      color: colors.onSurface,
      fontWeight: FontWeight.w600,
      decoration: TextDecoration.none,
    );
    final labelWidths = labels.map((label) {
      final painter = TextPainter(
        text: TextSpan(text: label, style: labelStyle),
        textDirection: Directionality.of(context),
        textScaler: scaler,
      )..layout();
      final width = painter.width.ceilToDouble() + 58;
      painter.dispose();
      return width;
    }).toList();
    final fullDockWidth = labelWidths.reduce((a, b) => a + b) + 12;
    Widget item(int i, {bool compact = false}) => Semantics(
      selected: selected == i,
      button: true,
      child: Tooltip(
        message: compact ? labels[i] : '',
        child: InkWell(
          key: ValueKey('nav-${keys[i]}'),
          borderRadius: BorderRadius.circular(28),
          splashFactory: NoSplash.splashFactory,
          highlightColor: Colors.transparent,
          hoverColor: Colors.transparent,
          onTap: callbacks[i],
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: bottom ? 4 : 14,
              vertical: bottom ? 9 : 12,
            ),
            child: bottom
                ? Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(icons[i], size: 21, color: colors.onSurfaceVariant),
                      const SizedBox(height: 4),
                      Text(
                        labels[i],
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: labelStyle.copyWith(
                          fontWeight: selected == i
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ],
                  )
                : Row(
                    mainAxisAlignment: rail
                        ? MainAxisAlignment.start
                        : MainAxisAlignment.center,
                    children: [
                      Icon(icons[i], size: 20, color: colors.onSurfaceVariant),
                      if (!compact) ...[
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            labels[i],
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: labelStyle.copyWith(
                              fontWeight: selected == i
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
          ),
        ),
      ),
    );

    Widget dock({bool compact = false}) {
      final itemHeight = bottom
          ? (43 + scaler.scale(11) * 1.5).clamp(64.0, double.infinity)
          : (24 + scaler.scale(13) * 1.5).clamp(48.0, double.infinity);
      Widget contents(double innerWidth) {
        final widths = List.generate(
          4,
          (i) => rail
              ? innerWidth
              : bottom || compact
              ? innerWidth / 4
              : labelWidths[i],
        );
        final itemWidth = widths[selected];
        final before = widths.take(selected).fold(0.0, (a, b) => a + b);
        final left = Directionality.of(context) == TextDirection.rtl
            ? innerWidth - before - itemWidth
            : before;
        return Container(
          key: ValueKey('navigation-${mode.name}'),
          width: innerWidth + 12,
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            color: colors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(32),
            border: Border.all(
              color: colors.outlineVariant.withValues(alpha: .45),
            ),
          ),
          child: SizedBox(
            width: innerWidth,
            height: rail ? itemHeight * 4 : itemHeight,
            child: Stack(
              children: [
                // A single opaque indicator travels between destinations. The old
                // button never fades through grey and icon colors stay constant.
                AnimatedPositioned(
                  duration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : const Duration(milliseconds: 380),
                  curve: const Cubic(.2, .85, .25, 1),
                  left: rail ? 0 : left,
                  top: rail ? selected * itemHeight : 0,
                  width: itemWidth,
                  height: itemHeight,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      key: const ValueKey('nav-selection-indicator'),
                      decoration: BoxDecoration(
                        color: colors.surface,
                        borderRadius: BorderRadius.circular(28),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: .05),
                            blurRadius: 10,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (rail)
                  Column(
                    children: [
                      for (var i = 0; i < 4; i++)
                        SizedBox(
                          width: widths[i],
                          height: itemHeight,
                          child: item(i),
                        ),
                    ],
                  )
                else
                  Row(
                    children: [
                      for (var i = 0; i < 4; i++)
                        SizedBox(
                          width: widths[i],
                          height: itemHeight,
                          child: item(i, compact: compact),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        );
      }

      return rail || bottom
          ? LayoutBuilder(
              builder: (_, bounds) =>
                  contents((bounds.maxWidth - 12).clamp(0.0, double.infinity)),
            )
          : contents(compact ? 48 * 4 : fullDockWidth - 12);
    }

    Widget brand({bool name = true}) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Image.asset(
          'assets/brand/konata-ui.png',
          key: const ValueKey('konata-brand-icon'),
          width: 36,
          height: 36,
          filterQuality: FilterQuality.medium,
        ),
        if (name) ...[
          const SizedBox(width: 10),
          const Text(
            'Konata',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
          ),
        ],
      ],
    );
    final dark = Theme.of(context).brightness == Brightness.dark;
    final themeButton = IconButton(
      key: const ValueKey('toggle-theme'),
      tooltip: dark ? context.l10n.switchLight : context.l10n.switchDark,
      icon: Icon(
        dark ? Icons.dark_mode_outlined : Icons.light_mode_outlined,
        size: 20,
      ),
      onPressed: () async {
        try {
          await AppTheme.instance.setMode(
            dark ? ThemeMode.light : ThemeMode.dark,
          );
        } catch (_) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(context.l10n.themeSaveFailed)),
            );
          }
        }
      },
    );
    if (bottom) {
      return Material(
        color: colors.surface,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
            child: Center(
              heightFactor: 1,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: dock(),
              ),
            ),
          ),
        ),
      );
    }
    if (rail) {
      return Material(
        color: colors.surface,
        child: Container(
          width: 172,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
          decoration: BoxDecoration(
            border: Border(
              right: BorderSide(
                color: colors.outlineVariant.withValues(alpha: .45),
              ),
            ),
          ),
          child: Column(
            children: [
              FittedBox(fit: BoxFit.scaleDown, child: brand()),
              const SizedBox(height: 24),
              dock(),
              const Spacer(),
              themeButton,
            ],
          ),
        ),
      );
    }
    return Material(
      color: colors.surface,
      child: LayoutBuilder(
        builder: (context, bounds) => Container(
          height: 72,
          padding: EdgeInsets.symmetric(
            horizontal: bounds.maxWidth < 600 ? 2 : 16,
          ),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: colors.outlineVariant.withValues(alpha: .45),
              ),
            ),
          ),
          child: Row(
            children: [
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
              else ...[
                if (bounds.maxWidth >= 500) ...[
                  brand(name: bounds.maxWidth >= 900),
                  SizedBox(width: bounds.maxWidth >= 900 ? 32 : 12),
                ],
                dock(
                  compact:
                      bounds.maxWidth < 850 ||
                      fullDockWidth >
                          bounds.maxWidth -
                              (bounds.maxWidth >= 900 ? 400 : 285) ||
                      MediaQuery.textScalerOf(context).scale(13) > 18,
                ),
                Expanded(
                  child: desktop && mobile != true
                      ? const DragToMoveArea(child: SizedBox.expand())
                      : const SizedBox(),
                ),
              ],
              themeButton,
              if (desktop && mobile != true) const WindowActions(),
            ],
          ),
        ),
      ),
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
