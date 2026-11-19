import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/detail_display_preferences_provider.dart';
import '../theme/konata_palette.dart';
import '../widgets/design_system/konata_dropdown.dart';
import '../widgets/design_system/konata_surface_card.dart';
import '../widgets/design_system/konata_switch.dart';
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
    final titleDropdownWidth = MediaQuery.sizeOf(context).width < 390
        ? 156.0
        : 172.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KonataSurfaceCard(
          padding: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              KonataListTile(
                title: '详情页标题',
                estimatedTrailingWidth: titleDropdownWidth,
                leading: Icon(
                  Icons.title_rounded,
                  size: 20,
                  color: p.textSecondary,
                ),
                trailing: SizedBox(
                  width: titleDropdownWidth,
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
                title: '作品简介',
                leading: Icon(
                  Icons.subject_rounded,
                  size: 20,
                  color: p.textSecondary,
                ),
                trailing: KonataSwitch(
                  value: prefs.showOverview,
                  onChanged: notifier.setShowOverview,
                ),
              ),
              Divider(height: 1, color: p.hairline, indent: 18, endIndent: 18),
              KonataListTile(
                title: '原始视频文件名',
                leading: Icon(
                  Icons.subtitles_outlined,
                  size: 20,
                  color: p.textSecondary,
                ),
                trailing: KonataSwitch(
                  value: prefs.showRawVideoFilename,
                  onChanged: notifier.setShowRawVideoFilename,
                ),
              ),
              Divider(height: 1, color: p.hairline, indent: 18, endIndent: 18),
              KonataListTile(
                title: '「CD」分类页签',
                leading: Icon(
                  Icons.album_outlined,
                  size: 20,
                  color: p.textSecondary,
                ),
                trailing: KonataSwitch(
                  value: prefs.showCdTab,
                  onChanged: notifier.setShowCdTab,
                ),
              ),
              Divider(height: 1, color: p.hairline, indent: 18, endIndent: 18),
              KonataListTile(
                title: '「Scan」分类页签',
                leading: Icon(
                  Icons.photo_library_outlined,
                  size: 20,
                  color: p.textSecondary,
                ),
                trailing: KonataSwitch(
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
