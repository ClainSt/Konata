import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/detail_display_preferences_provider.dart';
import '../../application/providers/library_providers.dart';
import '../../application/providers/theme_providers.dart';
import '../../application/providers/work_management_provider.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/konata_pill_button.dart';
import '../widgets/design_system/konata_segmented_capsule.dart';
import '../widgets/design_system/konata_surface_card.dart';
import '../widgets/design_system/konata_toast.dart';
import 'settings_photos_storage_card.dart';

/// 外观与显示设置面板（支持 暗色 / 亮色 / 跟随系统 主题与 Acrylic / Mica 窗口材质切换）。
class SettingsAppearancePanel extends ConsumerWidget {
  /// 创建外观与显示面板。
  const SettingsAppearancePanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final currentMode = ref.watch(themeModeProvider);
    final currentMaterial = ref.watch(windowMaterialProvider);
    final hiddenWorks = ref.watch(hiddenWorksProvider).valueOrNull ?? const [];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '外观与显示',
          style: KonataTheme.h2Style(p),
        ),
        const SizedBox(height: 6),
        Text(
          '选择全站主题模式与 Windows 11 原生 DWM 透明材质，更改后立即生效',
          style: KonataTheme.captionStyle(p, fontSize: 13),
        ),
        const SizedBox(height: 18),
        KonataSurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '主题模式',
                style: TextStyle(
                  color: p.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 14),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _ThemeOptionCard(
                      label: '深色模式',
                      subtitle: '影院黑曜石',
                      selected: currentMode == ThemeMode.dark,
                      previewBg: KonataTheme.cinemaObsidian,
                      previewCard: KonataTheme.themePreviewDarkCard,
                      previewPill: KonataPalette.dark.primaryButtonBg,
                      onTap: () => ref
                          .read(themeModeProvider.notifier)
                          .setThemeMode(ThemeMode.dark),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _ThemeOptionCard(
                      label: '浅色模式',
                      subtitle: '画册米白',
                      selected: currentMode == ThemeMode.light,
                      previewBg: KonataTheme.themePreviewLightCanvas,
                      previewCard: Colors.white,
                      previewPill: KonataPalette.light.primaryButtonBg,
                      onTap: () => ref
                          .read(themeModeProvider.notifier)
                          .setThemeMode(ThemeMode.light),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _ThemeOptionCard(
                      label: '跟随系统',
                      subtitle: '自动适配 Windows',
                      selected: currentMode == ThemeMode.system,
                      previewBg: KonataTheme.themePreviewDarkCard,
                      previewCard: KonataTheme.themePreviewLightCanvas,
                      previewPill: KonataTheme.themePreviewNeutralPill,
                      isSplitPreview: true,
                      onTap: () => ref
                          .read(themeModeProvider.notifier)
                          .setThemeMode(ThemeMode.system),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        KonataSurfaceCard(
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '窗口材质',
                      style: TextStyle(
                        color: p.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      currentMaterial.subtitle,
                      style: TextStyle(
                        color: p.textSecondary,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              KonataSegmentedCapsule<KonataWindowMaterial>(
                selected: currentMaterial,
                options: const [
                  KonataSegmentOption(
                    value: KonataWindowMaterial.acrylic,
                    label: '亚克力',
                  ),
                  KonataSegmentOption(
                    value: KonataWindowMaterial.mica,
                    label: '云母',
                  ),
                  KonataSegmentOption(
                    value: KonataWindowMaterial.tabbed,
                    label: '云母变体',
                  ),
                ],
                onChanged: (value) =>
                    ref.read(windowMaterialProvider.notifier).setMaterial(value),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        KonataSurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '已隐藏作品 (${hiddenWorks.length})',
                style: TextStyle(
                  color: p.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                hiddenWorks.isEmpty
                    ? '当前没有隐藏任何作品；在详情页右下角齿轮菜单中可隐藏指定作品'
                    : '以下作品在媒体库主视图中保持隐藏，可随时恢复显示',
                style: TextStyle(color: p.textSecondary, fontSize: 12.5),
              ),
              if (hiddenWorks.isNotEmpty) ...[
                const SizedBox(height: 12),
                for (final work in hiddenWorks)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${work.title}${work.year != null ? ' (${work.year})' : ''}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: p.textPrimary,
                              fontSize: 13.5,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        KonataPillButton.secondary(
                          label: '恢复显示',
                          compact: true,
                          onPressed: () async {
                            await ref
                                .read(workManagementProvider)
                                .unhideWork(work.id);
                            if (context.mounted) {
                              showKonataToast(context, '已恢复显示：${work.title}');
                            }
                          },
                        ),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        const _DetailDisplaySettingsCard(),
        const SizedBox(height: 16),
        const SettingsPhotosStorageCard(),
      ],
    );
  }
}

class _DetailDisplaySettingsCard extends ConsumerWidget {
  const _DetailDisplaySettingsCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final prefs = ref.watch(detailDisplayPreferencesProvider);
    final notifier = ref.read(detailDisplayPreferencesProvider.notifier);

    return KonataSurfaceCard(
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
    );
  }
}

class _ThemeOptionCard extends StatelessWidget {
  const _ThemeOptionCard({
    required this.label,
    required this.subtitle,
    required this.selected,
    required this.previewBg,
    required this.previewCard,
    required this.previewPill,
    required this.onTap,
    this.isSplitPreview = false,
  });

  final String label;
  final String subtitle;
  final bool selected;
  final Color previewBg;
  final Color previewCard;
  final Color previewPill;
  final VoidCallback onTap;
  final bool isSplitPreview;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: p.softFill,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? p.textPrimary : p.hairline,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  height: 62,
                  width: double.infinity,
                  child: isSplitPreview
                      ? Row(
                          children: [
                            Expanded(child: Container(color: previewBg)),
                            Expanded(child: Container(color: previewCard)),
                          ],
                        )
                      : Container(
                          color: previewBg,
                          padding: const EdgeInsets.all(8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                width: 38,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: previewPill,
                                  borderRadius: BorderRadius.circular(999),
                                ),
                              ),
                              const SizedBox(height: 8),
                              Expanded(
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: previewCard,
                                    borderRadius: BorderRadius.circular(5),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      style: TextStyle(
                        color: p.textPrimary,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (selected)
                    Icon(
                      Icons.check_circle_rounded,
                      size: 16,
                      color: p.textPrimary,
                    ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(
                  color: p.textMuted,
                  fontSize: 11.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
