import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';

/// 设置页统一 38×38 柔光前缀图标盒（供关于等卡片行统一复用）。
class KonataSettingsLeadingBox extends StatelessWidget {
  /// 创建前缀图标盒。
  const KonataSettingsLeadingBox({
    super.key,
    required this.child,
    this.backgroundColor,
    this.borderColor,
  });

  /// 居中展示的图标或微标文本。
  final Widget child;

  /// 可选底色覆盖（默认 `p.softFill`）。
  final Color? backgroundColor;

  /// 可选边框色覆盖（默认 `p.hairline`）。
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return SizedBox(
      width: 38,
      height: 38,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: backgroundColor ?? p.softFill,
          borderRadius: KonataTheme.borderRadiusControl,
          border: Border.all(color: borderColor ?? p.hairline, width: 1),
        ),
        child: Center(child: child),
      ),
    );
  }
}

/// 设置卡片内的紧凑开关项（支持可选副标题说明与禁用态）。
class KonataSettingsSwitchRow extends StatelessWidget {
  /// 创建紧凑开关行。
  const KonataSettingsSwitchRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.enabled = true,
  });

  /// 主标签文本。
  final String label;

  /// 可选副标题说明。
  final String? subtitle;

  /// 当前开关状态。
  final bool value;

  /// 状态变更回调。
  final ValueChanged<bool>? onChanged;

  /// 是否允许交互。
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final effectiveOnChanged = enabled ? onChanged : null;
    final isDisabled = effectiveOnChanged == null;
    return Row(
      crossAxisAlignment: subtitle != null
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: isDisabled ? p.textMuted : p.textPrimary,
                  fontSize: KonataTheme.fontSizeBodySm,
                ),
              ),
              if (subtitle != null && subtitle!.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle!,
                  style: TextStyle(
                    color: p.textMuted,
                    fontSize: KonataTheme.fontSizeBodyXs,
                    height: 1.35,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 12),
        KonataSwitch(value: value, onChanged: effectiveOnChanged),
      ],
    );
  }
}

/// 设置页分区标题卡头。
class SettingsSectionHeader extends StatelessWidget {
  /// 创建设置分区标题组件。
  const SettingsSectionHeader({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  /// 标题前置图标。
  final IconData icon;

  /// 主标题文案。
  final String title;

  /// 可选说明副标题。
  final String? subtitle;

  /// 可选右侧附属控件。
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<KonataPalette>()!;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(icon, size: 20, color: tokens.accent),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 15.5,
                  fontWeight: FontWeight.w700,
                  color: tokens.textPrimary,
                ),
              ),
              if (subtitle != null && subtitle!.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle!,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: tokens.textSecondary,
                    height: 1.4,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: 8),
          trailing!,
        ],
      ],
    );
  }
}

/// 标准开关设置条目行。
class SettingsSwitchTile extends StatelessWidget {
  /// 创建开关设置条目。
  const SettingsSwitchTile({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  /// 主标题。
  final String title;

  /// 辅助说明文案。
  final String? subtitle;

  /// 当前开关状态。
  final bool value;

  /// 状态变更回调。
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<KonataPalette>()!;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: tokens.textPrimary,
                ),
              ),
              if (subtitle != null && subtitle!.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle!,
                  style: TextStyle(
                    fontSize: 12,
                    color: tokens.textSecondary,
                    height: 1.35,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 12),
        KonataSwitch(value: value, onChanged: onChanged),
      ],
    );
  }
}

/// 带可选帮助说明按钮的文本输入标签标题。
class SettingsFieldLabel extends StatelessWidget {
  /// 创建输入标签行。
  const SettingsFieldLabel({
    super.key,
    required this.label,
    this.badgeText,
    this.onHelpTap,
  });

  /// 字段标题。
  final String label;

  /// 右侧轻量标识胶囊文案。
  final String? badgeText;

  /// 可选问号帮助弹窗回调。
  final VoidCallback? onHelpTap;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<KonataPalette>()!;
    return Row(
      children: [
        Expanded(
          child: Row(
            children: [
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: tokens.textPrimary,
                  ),
                ),
              ),
              if (badgeText != null && badgeText!.isNotEmpty) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: tokens.accent.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    badgeText!,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: tokens.accent,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        if (onHelpTap != null)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onHelpTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.help_outline_rounded,
                    size: 16,
                    color: tokens.accent,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '如何获取',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: tokens.accent,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
