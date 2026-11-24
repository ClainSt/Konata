import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../providers.dart';
import '../state/settings_controller.dart';

/// 外观设置面板（管理 暗色 / 亮色 / 跟随系统 主题预览卡、Windows 窗口材质与流光氛围画布）。
class SettingsAppearancePanel extends ConsumerWidget {
  /// 创建外观设置面板。
  const SettingsAppearancePanel({
    super.key,
    this.controller,
    this.isWindowsOverride,
  });

  /// 可选直传设置控制器；为空时从 [settingsControllerProvider] 获取。
  final SettingsController? controller;

  /// 可选平台覆盖标记（便于无依赖直传控制器单测控制桌面专属分区显隐）。
  final bool? isWindowsOverride;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final direct = controller;
    final SettingsController effectiveController =
        direct ?? ref.watch(settingsControllerProvider);
    final bool showWindowsOptions =
        isWindowsOverride ??
        (direct != null
            ? KonataAdaptiveTokens.isWindows
            : ref.watch(featureSettingsDependenciesProvider).currentPlatform ==
                  KonataPlatform.windows);
    final p = context.palette;

    return AnimatedBuilder(
      animation: effectiveController,
      builder: (context, _) {
        final currentMode = effectiveController.themeMode;
        final currentMaterial = showWindowsOptions
            ? effectiveController.windowMaterial
            : KonataWindowMaterial.acrylic;
        final ambientCanvasEnabled = showWindowsOptions
            ? effectiveController.ambientBackdropEnabled
            : true;

        final cards = [
          _ThemeOptionCard(
            key: const ValueKey('settings_theme_card_dark'),
            label: '深色模式',
            subtitle: '影院黑曜石',
            selected: currentMode == ThemeMode.dark,
            previewBg: KonataTheme.cinemaObsidian,
            previewCard: KonataTheme.themePreviewDarkCard,
            previewPill: KonataPalette.dark.primaryButtonBg,
            onTap: () => effectiveController.setThemeMode(ThemeMode.dark),
          ),
          _ThemeOptionCard(
            key: const ValueKey('settings_theme_card_light'),
            label: '浅色模式',
            subtitle: '画册米白',
            selected: currentMode == ThemeMode.light,
            previewBg: KonataTheme.themePreviewLightCanvas,
            previewCard: KonataTheme.pureWhite,
            previewPill: KonataPalette.light.primaryButtonBg,
            onTap: () => effectiveController.setThemeMode(ThemeMode.light),
          ),
          _ThemeOptionCard(
            key: const ValueKey('settings_theme_card_system'),
            label: '跟随系统',
            subtitle: '自动适配系统',
            selected: currentMode == ThemeMode.system,
            previewBg: KonataTheme.themePreviewDarkCard,
            previewCard: KonataTheme.themePreviewLightCanvas,
            previewPill: KonataTheme.themePreviewNeutralPill,
            isSplitPreview: true,
            onTap: () => effectiveController.setThemeMode(ThemeMode.system),
          ),
        ];

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            KonataSurfaceCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '主题模式',
                    style: TextStyle(
                      color: p.textPrimary,
                      fontSize: KonataTheme.fontSizeTitleSm,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 14),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      if (constraints.maxWidth >= 460) {
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (var i = 0; i < cards.length; i++) ...[
                              if (i > 0) const SizedBox(width: 12),
                              Expanded(child: cards[i]),
                            ],
                          ],
                        );
                      }
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var i = 0; i < cards.length; i++) ...[
                            if (i > 0) const SizedBox(height: 10),
                            cards[i],
                          ],
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
            if (showWindowsOptions) ...[
              const SizedBox(height: 16),
              KonataSurfaceCard(
                key: const ValueKey('settings_windows_material_card'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AdaptiveSettingTile(
                      padding: EdgeInsets.zero,
                      title: '窗口材质',
                      subtitle: currentMaterial.subtitle,
                      estimatedTrailingWidth: 220,
                      trailing: KonataSegmentedCapsule<KonataWindowMaterial>(
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
                        onChanged: effectiveController.setWindowMaterial,
                      ),
                    ),
                    Divider(height: 28, color: p.hairline),
                    AdaptiveSettingTile(
                      padding: EdgeInsets.zero,
                      title: '流光氛围画布',
                      subtitle: '在桌面窗口底层叠加柔焦极光氛围层（关闭时保持原生桌面透光材质）',
                      estimatedTrailingWidth: 64,
                      trailing: KonataSwitch(
                        key: const ValueKey('settings_ambient_canvas_switch'),
                        value: ambientCanvasEnabled,
                        onChanged: effectiveController.setAmbientBackdropEnabled,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _ThemeOptionCard extends StatelessWidget {
  const _ThemeOptionCard({
    super.key,
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

  Widget _buildThemePreviewTile({
    required Color bg,
    required Color pill,
    required Color card,
  }) {
    return DecoratedBox(
      decoration: BoxDecoration(color: bg),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: pill,
                borderRadius: KonataTheme.borderRadiusPill,
              ),
              child: const SizedBox(width: 28, height: 7),
            ),
            const SizedBox(height: 7),
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: card,
                  borderRadius: KonataTheme.borderRadiusChipSm,
                ),
                child: const SizedBox.expand(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: KonataTheme.opticalSheenGradient(
              p,
              baseColor: p.softFill,
            ),
            borderRadius: KonataTheme.borderRadiusCard,
            border: Border.all(
              color: selected ? p.textPrimary : p.hairline,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: KonataTheme.borderRadiusSm,
                  child: SizedBox(
                    height: 62,
                    width: double.infinity,
                    child: isSplitPreview
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(
                                child: _buildThemePreviewTile(
                                  bg: KonataTheme.cinemaObsidian,
                                  pill: KonataPalette.dark.primaryButtonBg,
                                  card: KonataTheme.themePreviewDarkCard,
                                ),
                              ),
                              ColoredBox(
                                color: p.hairline,
                                child: const SizedBox(width: 1),
                              ),
                              Expanded(
                                child: _buildThemePreviewTile(
                                  bg: KonataTheme.themePreviewLightCanvas,
                                  pill: KonataPalette.light.primaryButtonBg,
                                  card: KonataTheme.pureWhite,
                                ),
                              ),
                            ],
                          )
                        : _buildThemePreviewTile(
                            bg: previewBg,
                            pill: previewPill,
                            card: previewCard,
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
                          fontSize: KonataTheme.fontSizeBody,
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
                    fontSize: KonataTheme.fontSizeCaptionSm,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
