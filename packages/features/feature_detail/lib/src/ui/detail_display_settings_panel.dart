import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../providers.dart';

/// 详情页主视觉标题区可选展示元素。
enum _DetailTitleDisplayElement { textTitle, titleLogo }

/// 在设置页调整作品详情的标题、信息与分类显示。
class DetailDisplaySettingsPanel extends ConsumerWidget {
  /// 创建显示设置面板。
  const DetailDisplaySettingsPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.watch(detailDisplayPreferencesStoreProvider);
    final prefs =
        ref.watch(detailDisplayPreferencesProvider).value ?? store.read();
    final p = context.palette;
    final titleDropdownWidth = MediaQuery.sizeOf(context).width < 390
        ? 156.0
        : 172.0;

    return KonataSurfaceCard(
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
              child: KonataSegmentedCapsule<_DetailTitleDisplayElement>(
                key: const ValueKey('settings_display_title_segmented'),
                compact: true,
                expand: true,
                selected: prefs.showTitleLogo
                    ? _DetailTitleDisplayElement.titleLogo
                    : _DetailTitleDisplayElement.textTitle,
                options: const [
                  KonataSegmentOption(
                    value: _DetailTitleDisplayElement.textTitle,
                    label: '文字标题',
                  ),
                  KonataSegmentOption(
                    value: _DetailTitleDisplayElement.titleLogo,
                    label: '标题徽标',
                  ),
                ],
                onChanged: (item) => store.setShowTitleLogo(
                  item == _DetailTitleDisplayElement.titleLogo,
                ),
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
              key: const ValueKey('settings_display_overview_switch'),
              value: prefs.showOverview,
              onChanged: store.setShowOverview,
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
              key: const ValueKey('settings_display_raw_filename_switch'),
              value: prefs.showRawVideoFilename,
              onChanged: store.setShowRawVideoFilename,
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
              key: const ValueKey('settings_display_cd_tab_switch'),
              value: prefs.showCdTab,
              onChanged: store.setShowCdTab,
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
              key: const ValueKey('settings_display_scan_tab_switch'),
              value: prefs.showScanTab,
              onChanged: store.setShowScanTab,
            ),
          ),
        ],
      ),
    );
  }
}
