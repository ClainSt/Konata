import 'dart:io';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import '../core/app_theme.dart';

class AppHeader extends StatelessWidget {
  const AppHeader({
    super.key,
    required this.showSources,
    required this.onNavigate,
    required this.onSettings,
  });
  final bool showSources;
  final ValueChanged<bool> onNavigate;
  final VoidCallback onSettings;
  static bool get desktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  @override
  Widget build(BuildContext context) {
    if (!desktop) {
      return Material(
        child: SafeArea(
          top: false,
          child: NavigationBar(
            selectedIndex: showSources ? 1 : 0,
            onDestinationSelected: (index) {
              if (index == 2) {
                onSettings();
              } else {
                onNavigate(index == 1);
              }
            },
            destinations: const [
              NavigationDestination(
                key: ValueKey('nav-library'),
                icon: Icon(Icons.video_library_outlined),
                label: '媒体库',
              ),
              NavigationDestination(
                key: ValueKey('nav-sources'),
                icon: Icon(Icons.storage_outlined),
                label: '媒体源',
              ),
              NavigationDestination(
                icon: Icon(Icons.settings_outlined),
                label: '设置',
              ),
            ],
          ),
        ),
      );
    }
    final dark = Theme.of(context).brightness == Brightness.dark;
    return LayoutBuilder(
      builder: (context, bounds) => Material(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: SafeArea(
          bottom: false,
          child: SizedBox(
            height: 72,
            child: Row(
              children: [
                const SizedBox(width: 8),
                for (final entry in [(false, '媒体库'), (true, '媒体源')])
                  InkWell(
                    key: ValueKey('nav-${entry.$1 ? 'sources' : 'library'}'),
                    onTap: () => onNavigate(entry.$1),
                    child: Container(
                      width: 104,
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
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
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w700,
                                    color: showSources == entry.$1
                                        ? Theme.of(context).colorScheme.primary
                                        : Theme.of(context)
                                              .colorScheme
                                              .onSurface
                                              .withValues(alpha: .6),
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
                                  ? Theme.of(context).colorScheme.primary
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
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
                  tooltip: dark ? '切换到日间模式' : '切换到夜间模式',
                  icon: Icon(
                    dark ? Icons.dark_mode_outlined : Icons.light_mode_outlined,
                  ),
                  onPressed: () async {
                    try {
                      await AppTheme.instance.setMode(
                        dark ? ThemeMode.light : ThemeMode.dark,
                      );
                    } catch (_) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('主题设置保存失败，请重试')),
                        );
                      }
                    }
                  },
                ),
                IconButton(
                  key: const ValueKey('open-settings'),
                  style: IconButton.styleFrom(fixedSize: const Size(48, 48)),
                  tooltip: '设置',
                  onPressed: onSettings,
                  color: Theme.of(context).colorScheme.onSurface,
                  iconSize: 24,
                  icon: const Icon(Icons.settings),
                ),
                if (desktop && bounds.maxWidth >= 600) const _WindowActions(),
                if (!desktop) const SizedBox(width: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _WindowActions extends StatefulWidget {
  const _WindowActions();
  @override
  State<_WindowActions> createState() => _WindowActionsState();
}

class _WindowActionsState extends State<_WindowActions> with WindowListener {
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
        ('最小化', Icons.remove, () async => windowManager.minimize()),
        (
          maximized ? '还原' : '最大化',
          maximized ? Icons.filter_none : Icons.crop_square,
          () async {
            if (await windowManager.isMaximized()) {
              await windowManager.unmaximize();
            } else {
              await windowManager.maximize();
            }
          },
        ),
        ('关闭', Icons.close, () async => windowManager.close()),
      ])
        IconButton(
          key: ValueKey('window-${action.$1}'),
          tooltip: action.$1,
          onPressed: action.$3,
          style: IconButton.styleFrom(fixedSize: const Size(48, 48)),
          color: Theme.of(context).colorScheme.onSurface,
          icon: Icon(action.$2, size: 24),
        ),
    ],
  );
}
