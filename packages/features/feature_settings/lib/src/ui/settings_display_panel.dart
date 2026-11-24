import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/settings_display_prefs.dart';
import '../providers.dart';
import '../state/settings_controller.dart';
import 'settings_photos_storage_card.dart';

/// 详情页主视觉标题区可选展示元素。
enum _DetailTitleDisplayElement { textTitle, titleLogo }

/// 显示设置面板：管理作品详情页信息层级、展示分类与本地图片存储。
class SettingsDisplayPanel extends ConsumerWidget {
  /// 创建显示设置面板。
  const SettingsDisplayPanel({super.key, this.controller});

  /// 可选直传设置控制器；为空时从 [settingsControllerProvider] 获取。
  final SettingsController? controller;

  String _titleSummary(SettingsDisplayPrefs prefs) {
    if (prefs.showTitleText && prefs.showTitleLogo) {
      return '文字标题 · 标题徽标';
    }
    if (prefs.showTitleLogo) return '标题徽标';
    if (prefs.showTitleText) return '文字标题';
    return '不显示';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final direct = controller;
    final SettingsController effectiveController =
        direct ?? ref.watch(settingsControllerProvider);
    final p = context.palette;
    final titleDropdownWidth = MediaQuery.sizeOf(context).width < 390
        ? 156.0
        : 172.0;

    return AnimatedBuilder(
      animation: effectiveController,
      builder: (context, _) {
        final prefs = effectiveController.displayPrefs;
        final selectedElements = <_DetailTitleDisplayElement>{
          if (prefs.showTitleText) _DetailTitleDisplayElement.textTitle,
          if (prefs.showTitleLogo) _DetailTitleDisplayElement.titleLogo,
        };

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
                      child:
                          KonataMultiSelectDropdown<_DetailTitleDisplayElement>(
                            key: const ValueKey(
                              'settings_display_title_dropdown',
                            ),
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
                                  effectiveController.setShowTitleText(
                                    !prefs.showTitleText,
                                  );
                                case _DetailTitleDisplayElement.titleLogo:
                                  effectiveController.setShowTitleLogo(
                                    !prefs.showTitleLogo,
                                  );
                              }
                            },
                          ),
                    ),
                  ),
                  Divider(
                    height: 1,
                    color: p.hairline,
                    indent: 18,
                    endIndent: 18,
                  ),
                  KonataListTile(
                    title: '作品简介',
                    leading: Icon(
                      Icons.subject_rounded,
                      size: 20,
                      color: p.textSecondary,
                    ),
                    trailing: KonataSwitch(
                      key: const ValueKey('settings_display_overview_switch'),
                      value: prefs.showOverview,
                      onChanged: effectiveController.setShowOverview,
                    ),
                  ),
                  Divider(
                    height: 1,
                    color: p.hairline,
                    indent: 18,
                    endIndent: 18,
                  ),
                  KonataListTile(
                    title: '原始视频文件名',
                    leading: Icon(
                      Icons.subtitles_outlined,
                      size: 20,
                      color: p.textSecondary,
                    ),
                    trailing: KonataSwitch(
                      key: const ValueKey(
                        'settings_display_raw_filename_switch',
                      ),
                      value: prefs.showRawVideoFilename,
                      onChanged: effectiveController.setShowRawVideoFilename,
                    ),
                  ),
                  Divider(
                    height: 1,
                    color: p.hairline,
                    indent: 18,
                    endIndent: 18,
                  ),
                  KonataListTile(
                    title: '「CD」分类页签',
                    leading: Icon(
                      Icons.album_outlined,
                      size: 20,
                      color: p.textSecondary,
                    ),
                    trailing: KonataSwitch(
                      key: const ValueKey('settings_display_cd_tab_switch'),
                      value: prefs.showCdTab,
                      onChanged: effectiveController.setShowCdTab,
                    ),
                  ),
                  Divider(
                    height: 1,
                    color: p.hairline,
                    indent: 18,
                    endIndent: 18,
                  ),
                  KonataListTile(
                    title: '「Scan」分类页签',
                    leading: Icon(
                      Icons.photo_library_outlined,
                      size: 20,
                      color: p.textSecondary,
                    ),
                    trailing: KonataSwitch(
                      key: const ValueKey('settings_display_scan_tab_switch'),
                      value: prefs.showScanTab,
                      onChanged: effectiveController.setShowScanTab,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SettingsPhotosStorageCard(controller: controller),
          ],
        );
      },
    );
  }
}
