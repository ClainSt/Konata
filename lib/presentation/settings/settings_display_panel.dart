import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/detail_display_preferences_provider.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/konata_dropdown.dart';
import '../widgets/design_system/konata_surface_card.dart';
import 'settings_photos_storage_card.dart';

/// 详情页主视觉标题区可选展示元素。
enum _DetailTitleDisplayElement { textTitle, titleLogo }

/// 显示设置面板：管理作品详情页信息层级、展示分类与本地图片存储。
class SettingsDisplayPanel extends ConsumerWidget {
  /// 创建显示设置面板。
  const SettingsDisplayPanel({super.key});

  String _titleSummary(DetailDisplayPreferences prefs) {
    if (prefs.showTitleText && prefs.showTitleLogo) {
      return '文字标题 · 标题徽标';
    }
    if (prefs.showTitleLogo) return '标题徽标';
    if (prefs.showTitleText) return '文字标题';
    return '不显示';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final prefs = ref.watch(detailDisplayPreferencesProvider);
    final notifier = ref.read(detailDisplayPreferencesProvider.notifier);

    final selectedElements = <_DetailTitleDisplayElement>{
      if (prefs.showTitleText) _DetailTitleDisplayElement.textTitle,
      if (prefs.showTitleLogo) _DetailTitleDisplayElement.titleLogo,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('显示', style: KonataTheme.h2Style(p)),
        const SizedBox(height: 6),
        Text(
          '管理作品详情页信息层级、展示分类与本地图片存储',
          style: KonataTheme.captionStyle(p, fontSize: 13),
        ),
        const SizedBox(height: 18),
        KonataSurfaceCard(
          padding: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
                child: Text(
                  '详情页显示',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              KonataListTile(
                title: '标题显示',
                subtitle: '自定义详情页主视觉区是否展示文字标题与透明标题徽标（可同时勾选或全取消）',
                leading: Icon(
                  Icons.title_rounded,
                  size: 20,
                  color: p.textSecondary,
                ),
                trailing: SizedBox(
                  width: 172,
                  child: KonataMultiSelectDropdown<_DetailTitleDisplayElement>(
                    dense: true,
                    menuWidth: 172,
                    centerAligned: true,
                    selectedValues: selectedElements,
                    displayText: _titleSummary(prefs),
                    options: const [
                      KonataDropdownOption(
                        value: _DetailTitleDisplayElement.textTitle,
                        label: '文字标题',
                      ),
                      KonataDropdownOption(
                        value: _DetailTitleDisplayElement.titleLogo,
                        label: '标题徽标',
                      ),
                    ],
                    onToggle: (item) {
                      switch (item) {
                        case _DetailTitleDisplayElement.textTitle:
                          notifier.setShowTitleText(!prefs.showTitleText);
                        case _DetailTitleDisplayElement.titleLogo:
                          notifier.setShowTitleLogo(!prefs.showTitleLogo);
                      }
                    },
                  ),
                ),
              ),
              Divider(height: 1, color: p.hairline, indent: 18, endIndent: 18),
              KonataListTile(
                title: '显示作品简介',
                subtitle: '在作品详情页元信息下方展示剧情简介与展开控制',
                leading: Icon(
                  Icons.subject_rounded,
                  size: 20,
                  color: p.textSecondary,
                ),
                trailing: Switch(
                  value: prefs.showOverview,
                  onChanged: notifier.setShowOverview,
                ),
              ),
              Divider(height: 1, color: p.hairline, indent: 18, endIndent: 18),
              KonataListTile(
                title: '显示原始视频文件名',
                subtitle: '在作品详情页正片与特典选集卡片下方展示原始文件名与格式标签',
                leading: Icon(
                  Icons.subtitles_outlined,
                  size: 20,
                  color: p.textSecondary,
                ),
                trailing: Switch(
                  value: prefs.showRawVideoFilename,
                  onChanged: notifier.setShowRawVideoFilename,
                ),
              ),
              Divider(height: 1, color: p.hairline, indent: 18, endIndent: 18),
              KonataListTile(
                title: '显示「CD」分类页签',
                subtitle: '在详情页底部选集栏与完整列表中展示 CD / OST 音轨（关闭后仅隐藏入口，不影响底层数据）',
                leading: Icon(
                  Icons.album_outlined,
                  size: 20,
                  color: p.textSecondary,
                ),
                trailing: Switch(
                  value: prefs.showCdTab,
                  onChanged: notifier.setShowCdTab,
                ),
              ),
              Divider(height: 1, color: p.hairline, indent: 18, endIndent: 18),
              KonataListTile(
                title: '显示「Scan」分类页签',
                subtitle: '在详情页底部选集栏与完整列表中展示 Scan / Booklet 扫图（关闭后立即停止微缩图加载队列）',
                leading: Icon(
                  Icons.photo_library_outlined,
                  size: 20,
                  color: p.textSecondary,
                ),
                trailing: Switch(
                  value: prefs.showScanTab,
                  onChanged: notifier.setShowScanTab,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        const SettingsPhotosStorageCard(),
      ],
    );
  }
}
