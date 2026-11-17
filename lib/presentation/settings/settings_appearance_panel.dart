import 'package:flutter/material.dart';
import '../theme/konata_adaptive_tokens.dart';
import '../widgets/design_system/konata_settings_row.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/theme_providers.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/konata_segmented_capsule.dart';
import '../widgets/design_system/konata_surface_card.dart';

/// 外观设置面板（仅管理 暗色 / 亮色 / 跟随系统 主题与 Acrylic / Mica 窗口材质切换）。
class SettingsAppearancePanel extends ConsumerWidget {
  /// 创建外观设置面板。
  const SettingsAppearancePanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final currentMode = ref.watch(themeModeProvider);
    final currentMaterial = ref.watch(windowMaterialProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('外观', style: KonataTheme.h2Style(p)),
        const SizedBox(height: 6),
        Text(
          '选择全站主题模式，更改后立即生效',
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
              KonataSettingsRow(
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
                      subtitle: '自动适配系统',
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
        if (KonataAdaptiveTokens.isWindows) ...[
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
                  onChanged: (value) => ref
                      .read(windowMaterialProvider.notifier)
                      .setMaterial(value),
                ),
              ],
            ),
          ),
        ],
      ],
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
                style: TextStyle(color: p.textMuted, fontSize: 11.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
