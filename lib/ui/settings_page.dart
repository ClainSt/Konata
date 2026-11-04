import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../core/app_theme.dart';
import '../core/metadata.dart';
import 'tmdb_settings_dialog.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _themeSelectorKey = GlobalKey();
  int selected = 0;
  static const labels = ['外观设置', '刮削设置', '关于'];
  static const icons = [
    Icons.palette_outlined,
    Icons.movie_filter_outlined,
    Icons.info_outline,
  ];

  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.all(16),
    child: SizedBox(
      width: 1160,
      height: 780,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 12, 12),
            child: Row(
              children: [
                const Text(
                  '设置',
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                IconButton(
                  tooltip: '关闭设置',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, bounds) {
                final compact = bounds.maxWidth < 600;
                final menu = ListView(
                  padding: const EdgeInsets.fromLTRB(8, 12, 20, 12),
                  children: [
                    for (var i = 0; i < labels.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Material(
                          key: ValueKey('settings-category-$i'),
                          color: selected == i
                              ? Theme.of(context).colorScheme.primary
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: () => setState(() => selected = i),
                            hoverColor: Theme.of(
                              context,
                            ).colorScheme.onSurface.withValues(alpha: .035),
                            child: SizedBox(
                              height: 64,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      icons[i],
                                      size: 24,
                                      color: selected == i
                                          ? AppTheme.instance.accent.foreground
                                          : Theme.of(context)
                                                .colorScheme
                                                .onSurface
                                                .withValues(alpha: .6),
                                    ),
                                    const SizedBox(width: 14),
                                    Expanded(
                                      child: Text(
                                        labels[i],
                                        maxLines: 1,
                                        softWrap: false,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 17,
                                          fontWeight: FontWeight.w600,
                                          color: selected == i
                                              ? AppTheme
                                                    .instance
                                                    .accent
                                                    .foreground
                                              : Theme.of(context)
                                                    .colorScheme
                                                    .onSurface
                                                    .withValues(alpha: .6),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    SizedBox(
                                      width: 20,
                                      child: selected == i
                                          ? Icon(
                                              Icons.chevron_right,
                                              size: 20,
                                              color: AppTheme
                                                  .instance
                                                  .accent
                                                  .foreground,
                                            )
                                          : null,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                );
                final content = ListView(
                  padding: const EdgeInsets.all(24),
                  children: [
                    if (selected != 0)
                      Text(
                        labels[selected],
                        style: const TextStyle(
                          fontSize: 21,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    if (selected != 0) const SizedBox(height: 24),
                    if (selected == 0) ...[
                      AnimatedBuilder(
                        animation: AppTheme.instance,
                        builder: (context, _) => Container(
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: Theme.of(
                                context,
                              ).dividerColor.withValues(alpha: .2),
                            ),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: LayoutBuilder(
                            builder: (context, rowBounds) {
                              final selector = Container(
                                key: _themeSelectorKey,
                                width: 160,
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    color: Theme.of(
                                      context,
                                    ).dividerColor.withValues(alpha: .2),
                                  ),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Builder(
                                  builder: (anchorContext) => TextButton(
                                    key: const ValueKey('settings-theme-mode'),
                                    onPressed: () =>
                                        _showThemeMenu(anchorContext),
                                    style: TextButton.styleFrom(
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(7),
                                      ),
                                      minimumSize: const Size(0, 48),
                                      tapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                      foregroundColor: Theme.of(
                                        context,
                                      ).colorScheme.onSurface,
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 12,
                                        horizontal: 15,
                                      ),
                                    ),
                                    child: Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: [
                                        Text(
                                          _modeLabel(AppTheme.instance.mode),
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        const Icon(Icons.keyboard_arrow_down),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                              return Padding(
                                padding: const EdgeInsets.all(20),
                                child: rowBounds.maxWidth < 470
                                    ? Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          _themeDescription(),
                                          const SizedBox(height: 16),
                                          selector,
                                        ],
                                      )
                                    : Row(
                                        children: [
                                          Expanded(child: _themeDescription()),
                                          const SizedBox(width: 20),
                                          selector,
                                        ],
                                      ),
                              );
                            },
                          ),
                        ),
                      ),
                    ],
                    if (selected == 0) ...[
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: Theme.of(
                              context,
                            ).dividerColor.withValues(alpha: .2),
                          ),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              '主题色',
                              style: TextStyle(
                                fontSize: 19,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 5),
                            const Text('选择应用界面的强调色'),
                            const SizedBox(height: 16),
                            Wrap(
                              spacing: 16,
                              runSpacing: 12,
                              children: [
                                for (final accent in ThemeAccent.values)
                                  Tooltip(
                                    message: accent.label,
                                    child: Semantics(
                                      button: true,
                                      selected:
                                          AppTheme.instance.accent == accent,
                                      label: accent.label,
                                      child: InkWell(
                                        key: ValueKey(
                                          'theme-accent-${accent.name}',
                                        ),
                                        borderRadius: BorderRadius.circular(24),
                                        onTap: () async {
                                          try {
                                            await AppTheme.instance.setAccent(
                                              accent,
                                            );
                                          } catch (_) {
                                            if (context.mounted) {
                                              ScaffoldMessenger.of(
                                                context,
                                              ).showSnackBar(
                                                const SnackBar(
                                                  content: Text('主题色保存失败，请重试'),
                                                ),
                                              );
                                            }
                                          }
                                        },
                                        child: Container(
                                          width: 48,
                                          height: 48,
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            color: accent.color,
                                            border: Border.all(
                                              color: accent.color.withValues(
                                                alpha: .5,
                                              ),
                                              width: 2,
                                            ),
                                          ),
                                          child:
                                              AppTheme.instance.accent == accent
                                              ? Icon(
                                                  Icons.check,
                                                  color: accent.foreground,
                                                )
                                              : null,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                    if (selected == 1) ...[
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.key_outlined),
                          title: const Text('TMDB API 设置'),
                          subtitle: Text(
                            Metadata.credentials.isConfigured
                                ? '已配置 · 支持访问令牌 / API Key'
                                : '未配置 · 设置访问令牌或 API Key',
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () async {
                            await TmdbSettingsDialog.show(context);
                            if (mounted) setState(() {});
                          },
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text('Bangumi 使用公开接口，无需配置 API 凭证。'),
                    ],
                    if (selected == 2) ...[
                      const Text(
                        'CCPlayer',
                        style: TextStyle(
                          fontSize: 30,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text('版本 1.0.0'),
                      const SizedBox(height: 24),
                      Card(
                        child: ListTile(
                          leading: Image.asset(
                            Theme.of(context).brightness == Brightness.dark
                                ? 'assets/brand/github-white.png'
                                : 'assets/brand/github-black.png',
                            width: 28,
                            height: 28,
                            semanticLabel: 'GitHub',
                          ),
                          title: const Text(
                            'ClainSt/CCPlayer',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: const Text(
                            'https://github.com/ClainSt/CCPlayer',
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () async {
                            try {
                              final opened = await launchUrl(
                                Uri.parse(
                                  'https://github.com/ClainSt/CCPlayer',
                                ),
                                mode: LaunchMode.externalApplication,
                              );
                              if (!opened) throw StateError('无法打开浏览器');
                            } catch (_) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      '无法打开浏览器，请访问 https://github.com/ClainSt/CCPlayer',
                                    ),
                                  ),
                                );
                              }
                            }
                          },
                        ),
                      ),
                      const SizedBox(height: 24),
                      const Text('个人动画媒体库与播放器'),
                      const SizedBox(height: 12),
                      const Text(
                        '支持本地、WebDAV 与 SMB 媒体源、目录浏览与扫描、TMDB / Bangumi 资料刮削、海报与元数据编辑，以及视频播放和观看进度。',
                      ),
                    ],
                  ],
                );
                if (compact) {
                  return Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: Wrap(
                          spacing: 8,
                          children: [
                            for (var i = 0; i < labels.length; i++)
                              ChoiceChip(
                                label: Text(labels[i]),
                                selected: selected == i,
                                onSelected: (_) => setState(() => selected = i),
                              ),
                          ],
                        ),
                      ),
                      Expanded(child: content),
                    ],
                  );
                }
                return Row(
                  children: [
                    SizedBox(width: 240, child: menu),

                    Expanded(child: content),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    ),
  );

  String _modeLabel(ThemeMode mode) => switch (mode) {
    ThemeMode.light => '日间模式',
    ThemeMode.dark => '夜间模式',
    ThemeMode.system => '跟随系统',
  };

  Future<void> _showThemeMenu(BuildContext anchorContext) async {
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final anchor =
        _themeSelectorKey.currentContext!.findRenderObject()! as RenderBox;
    final theme = Theme.of(context);
    final chosen = await showMenu<ThemeMode>(
      context: context,
      menuPadding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 160),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      clipBehavior: Clip.antiAlias,
      positionBuilder: (context, constraints) {
        final rect =
            anchor.localToGlobal(Offset.zero, ancestor: overlay) & anchor.size;
        const menuHeight = 144.0;
        const gap = 4.0;
        final bottomLimit =
            overlay.size.height - MediaQuery.paddingOf(context).bottom - 8;
        final top = rect.bottom + gap + menuHeight <= bottomLimit
            ? rect.bottom + gap
            : rect.top - gap - menuHeight;
        return RelativeRect.fromRect(
          Rect.fromLTWH(rect.left, top, rect.width, 0),
          Offset.zero & overlay.size,
        );
      },
      items: [
        for (final mode in [ThemeMode.light, ThemeMode.dark, ThemeMode.system])
          PopupMenuItem<ThemeMode>(
            value: mode,
            padding: EdgeInsets.zero,
            child: Container(
              height: 48,
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: AppTheme.instance.mode == mode
                    ? theme.colorScheme.primary.withValues(alpha: .18)
                    : null,
                border: Border(
                  bottom: BorderSide(
                    color: theme.dividerColor.withValues(alpha: .12),
                  ),
                ),
              ),
              child: Text(
                _modeLabel(mode),
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ),
          ),
      ],
    );
    if (chosen != null && mounted) await _changeTheme(chosen);
  }

  Widget _themeDescription() => Row(
    children: [
      Icon(
        Icons.dark_mode_outlined,
        size: 28,
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .65),
      ),
      const SizedBox(width: 16),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '主题模式',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 5),
            Text(
              '选择应用界面的颜色主题',
              style: TextStyle(
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: .65),
              ),
            ),
          ],
        ),
      ),
    ],
  );
  Future<void> _changeTheme(ThemeMode mode) async {
    try {
      await AppTheme.instance.setMode(mode);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('主题设置保存失败，请重试')));
      }
    }
  }
}
