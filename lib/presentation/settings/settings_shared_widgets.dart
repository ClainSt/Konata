import 'dart:developer' as developer;

import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme/konata_palette.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/konata_switch.dart';

/// 设置页统一 38×38 柔光前缀图标盒（供关于、备份同步、Bangumi 同步等面板唯一复用）。
class KonataSettingsLeadingBox extends StatelessWidget {
  /// 创建图标盒。
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

/// 设置卡片内的紧凑开关项（支持可选副标题说明与禁用态，供同步范围与策略配置复用）。
class KonataSettingsSwitchRow extends StatelessWidget {
  /// 创建开关项。
  const KonataSettingsSwitchRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.enabled = true,
  });

  final String label;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
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

/// 安全拉起系统外部浏览器打开指定链接（防非法 URL 或平台通道异常崩溃）。
Future<bool> openKonataExternalUrl(String url) async {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || (!uri.isScheme('http') && !uri.isScheme('https'))) {
    return false;
  }
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (error) {
    developer.log(
      '拉起外部链接失败：$url',
      name: 'konata.settings_shared_widgets',
      error: error,
    );
    return false;
  }
}

/// 将日期时间格式化为紧凑的 `YYYY.MM.DD HH:mm` 展示文本。
String formatKonataShortDateTime(DateTime dt) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${dt.year}.${two(dt.month)}.${two(dt.day)} '
      '${two(dt.hour)}:${two(dt.minute)}';
}

/// 生成导出文件名使用的本地时间戳后缀（`YYYYMMDD_HHmmss`）。
String buildKonataFileTimestampSuffix([DateTime? now]) {
  final dt = now ?? DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${dt.year}${two(dt.month)}${two(dt.day)}_'
      '${two(dt.hour)}${two(dt.minute)}${two(dt.second)}';
}
