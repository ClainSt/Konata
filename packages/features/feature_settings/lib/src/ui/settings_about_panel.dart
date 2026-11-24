import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../providers.dart';
import '../state/settings_controller.dart';
import 'settings_shared_widgets.dart';

/// 关于 Konata 信息与外部项目链接面板（纯设计系统组件实现）。
class SettingsAboutPanel extends ConsumerWidget {
  /// 创建关于 Konata 面板。
  const SettingsAboutPanel({super.key, this.controller});

  /// 可选直传设置控制器；为空时从 [settingsControllerProvider] 获取。
  final SettingsController? controller;

  static final Uri _githubRepoUri = Uri.parse(
    'https://github.com/clainst/Konata',
  );
  static final Uri _tmdbHomeUri = Uri.parse('https://www.themoviedb.org');
  static final Uri _bangumiHomeUri = Uri.parse('https://bgm.tv');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final direct = controller;
    final SettingsController effectiveController =
        direct ?? ref.watch(settingsControllerProvider);
    final tokens = Theme.of(context).extension<KonataPalette>()!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KonataSurfaceCard(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: tokens.accent.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: tokens.accent.withValues(alpha: 0.35),
                      ),
                    ),
                    child: Icon(
                      Icons.movie_filter_outlined,
                      size: 26,
                      color: tokens.accent,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Konata 动漫与音乐媒体库',
                          style: TextStyle(
                            fontSize: 16.5,
                            fontWeight: FontWeight.w700,
                            color: tokens.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '版本 ${effectiveController.appVersion} · 插件化三端统一架构',
                          style: TextStyle(
                            fontSize: 12.5,
                            color: tokens.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Divider(height: 1, color: tokens.hairline),
              const SizedBox(height: 14),
              Text(
                'Konata 将本地与远程媒体源整理为优雅的作品档案，采用微内核 + 声明式特性扩展机制，保持设置容器与各业务功能模块严格解耦，兼容 Windows、Android 平板与手机端。',
                style: TextStyle(
                  fontSize: 13,
                  color: tokens.textSecondary,
                  height: 1.55,
                ),
              ),
              const SizedBox(height: 16),
              const SettingsSectionHeader(
                icon: Icons.link_rounded,
                title: '相关社区与数据源致谢',
                subtitle: '通过系统安全浏览器端口打开以下外部链接',
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                children: [
                  KonataPillButton.secondary(
                    label: 'GitHub 开源主页',
                    icon: Icons.open_in_new_rounded,
                    compact: true,
                    onPressed: () =>
                        effectiveController.openExternalUrl(_githubRepoUri),
                  ),
                  KonataPillButton.secondary(
                    label: 'TMDB 影视数据库',
                    icon: Icons.open_in_new_rounded,
                    compact: true,
                    onPressed: () =>
                        effectiveController.openExternalUrl(_tmdbHomeUri),
                  ),
                  KonataPillButton.secondary(
                    label: 'Bangumi 番组计划',
                    icon: Icons.open_in_new_rounded,
                    compact: true,
                    onPressed: () =>
                        effectiveController.openExternalUrl(_bangumiHomeUri),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
