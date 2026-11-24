import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../providers.dart';
import '../state/settings_controller.dart';
import 'settings_shared_widgets.dart';

/// 关于页面板（Konata 图标、版本信息、结构化诊断日志导出与复制摘要、GitHub 与 TMDB 声明）。
class SettingsAboutPanel extends ConsumerWidget {
  /// 创建关于 Konata 面板。
  const SettingsAboutPanel({super.key, this.controller});

  /// 可选直传设置控制器；为空时从 [settingsControllerProvider] 获取。
  final SettingsController? controller;

  static final Uri _githubRepoUri = Uri.parse(
    KonataNetworkConfig.githubRepoUrl,
  );
  static final Uri _tmdbHomeUri = Uri.parse(KonataNetworkConfig.tmdbHomeUrl);

  Future<void> _exportReport(
    BuildContext context,
    SettingsController ctrl, {
    required bool asJson,
  }) async {
    try {
      final savedPath = await ctrl.exportDiagnosticBundle(asJson: asJson);
      if (!context.mounted) return;
      if (savedPath == null) {
        showKonataToast(context, '已取消导出诊断报告');
      } else {
        showKonataToast(context, '已导出诊断日志至 $savedPath');
      }
    } catch (e) {
      if (context.mounted) {
        showKonataToast(context, '导出诊断日志失败：$e', isError: true);
      }
    }
  }

  Future<void> _copyDiagnosticSummary(
    BuildContext context,
    SettingsController ctrl,
  ) async {
    try {
      final summary = await ctrl.buildCompactDiagnosticSummary();
      await Clipboard.setData(ClipboardData(text: summary));
      if (context.mounted) {
        showKonataToast(context, '已复制诊断定位摘要，可直接粘贴排查问题');
      }
    } catch (e) {
      if (context.mounted) {
        showKonataToast(context, '复制诊断摘要失败：$e', isError: true);
      }
    }
  }

  Widget _buildLeadingBox(Widget child, {Color? backgroundColor}) {
    return KonataSettingsLeadingBox(
      backgroundColor: backgroundColor,
      child: child,
    );
  }

  Widget _buildFallbackLogo(KonataPalette p) {
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: p.accent.withValues(alpha: 0.16),
        borderRadius: KonataTheme.borderRadiusCard,
        border: Border.all(color: p.accent.withValues(alpha: 0.35)),
      ),
      child: Icon(Icons.movie_filter_outlined, size: 26, color: p.accent),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final direct = controller;
    final SettingsController effectiveController =
        direct ?? ref.watch(settingsControllerProvider);
    final p = context.palette;

    return AnimatedBuilder(
      animation: effectiveController,
      builder: (context, _) {
        final counts = effectiveController.diagnosticCounts;
        final verboseEnabled = effectiveController.verboseDiagnosticsEnabled;
        final hasLogs =
            counts.totalEvents > 0 ||
            counts.errorCount > 0 ||
            counts.warningCount > 0 ||
            counts.breadcrumbCount > 0;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            KonataSurfaceCard(
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: KonataTheme.borderRadiusCard,
                    child: Image.asset(
                      'assets/icons/konata_icon.png',
                      width: 48,
                      height: 48,
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) => _buildFallbackLogo(p),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Konata',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: p.textPrimary,
                            fontSize: KonataTheme.fontSizeTitleLg,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '版本 ${effectiveController.appVersion}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: p.textSecondary,
                            fontSize: KonataTheme.fontSizeBodySm,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            KonataSurfaceCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  KonataListTile(
                    title: '详细调试日志',
                    subtitle:
                        '始终保留异常、子系统状态与操作轨迹（当前 ${counts.errorCount} 异常 · ${counts.warningCount} 警告 · ${counts.totalEvents} 事件）；复现复杂问题前可开启完整追踪。',
                    leading: _buildLeadingBox(
                      Icon(
                        Icons.bug_report_outlined,
                        size: 20,
                        color: p.textSecondary,
                      ),
                    ),
                    trailing: KonataSwitch(
                      key: const ValueKey('settings_about_verbose_switch'),
                      value: verboseEnabled,
                      onChanged: effectiveController.setDiagnosticVerbose,
                    ),
                  ),
                  Divider(
                    height: 1,
                    color: p.hairline,
                    indent: 18,
                    endIndent: 18,
                  ),
                  KonataListTile(
                    key: const ValueKey('settings_export_diagnostics_txt'),
                    title: '导出最近异常日志',
                    subtitle: '导出含故障源码锚点、当前运行态快照、操作轨迹与脱敏时间线的 TXT 诊断报告',
                    leading: _buildLeadingBox(
                      Icon(
                        Icons.description_outlined,
                        size: 20,
                        color: p.textSecondary,
                      ),
                    ),
                    trailing: Icon(
                      Icons.chevron_right_rounded,
                      size: 20,
                      color: p.textMuted,
                    ),
                    onTap: effectiveController.isExportingDiagnostics
                        ? null
                        : () => _exportReport(
                              context,
                              effectiveController,
                              asJson: false,
                            ),
                  ),
                  Divider(
                    height: 1,
                    color: p.hairline,
                    indent: 18,
                    endIndent: 18,
                  ),
                  KonataListTile(
                    key: const ValueKey('settings_export_diagnostics_json'),
                    title: '导出结构化诊断包 (.json)',
                    subtitle: '导出包含故障分诊、运行快照与操作轨迹的 Schema v3 结构化数据',
                    leading: _buildLeadingBox(
                      Icon(
                        Icons.data_object_rounded,
                        size: 20,
                        color: p.textSecondary,
                      ),
                    ),
                    trailing: Icon(
                      Icons.chevron_right_rounded,
                      size: 20,
                      color: p.textMuted,
                    ),
                    onTap: effectiveController.isExportingDiagnostics
                        ? null
                        : () => _exportReport(
                              context,
                              effectiveController,
                              asJson: true,
                            ),
                  ),
                  Divider(
                    height: 1,
                    color: p.hairline,
                    indent: 18,
                    endIndent: 18,
                  ),
                  KonataListTile(
                    key: const ValueKey('settings_copy_diagnostic_summary'),
                    title: '复制诊断定位摘要',
                    subtitle: '一键复制精简故障分诊、运行快照与最近 12 步操作轨迹至剪贴板',
                    leading: _buildLeadingBox(
                      Icon(
                        Icons.content_copy_rounded,
                        size: 19,
                        color: p.textSecondary,
                      ),
                    ),
                    trailing: Icon(
                      Icons.chevron_right_rounded,
                      size: 20,
                      color: p.textMuted,
                    ),
                    onTap: () =>
                        _copyDiagnosticSummary(context, effectiveController),
                  ),
                  if (hasLogs) ...[
                    Divider(
                      height: 1,
                      color: p.hairline,
                      indent: 18,
                      endIndent: 18,
                    ),
                    KonataListTile(
                      key: const ValueKey('settings_clear_diagnostics'),
                      title: '清空当前诊断缓冲',
                      subtitle: '清除内存中的历史日志与轨迹，方便干净复现下一次问题',
                      leading: _buildLeadingBox(
                        Icon(
                          Icons.cleaning_services_outlined,
                          size: 19,
                          color: p.textSecondary,
                        ),
                      ),
                      trailing: Icon(
                        Icons.chevron_right_rounded,
                        size: 20,
                        color: p.textMuted,
                      ),
                      onTap: () {
                        effectiveController.clearDiagnosticLogs();
                        showKonataToast(context, '已清空当前诊断日志缓冲');
                      },
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),
            KonataSurfaceCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  KonataListTile(
                    key: const ValueKey('settings_about_github_tile'),
                    title: 'ClainSt/Konata',
                    subtitle: KonataNetworkConfig.githubRepoUrl,
                    leading: _buildLeadingBox(
                      _GitHubOctocatIcon(color: p.textPrimary, size: 22),
                    ),
                    trailing: Icon(
                      Icons.chevron_right_rounded,
                      size: 20,
                      color: p.textMuted,
                    ),
                    onTap: () =>
                        effectiveController.openExternalUrl(_githubRepoUri),
                  ),
                  Divider(
                    height: 1,
                    color: p.hairline,
                    indent: 18,
                    endIndent: 18,
                  ),
                  KonataListTile(
                    key: const ValueKey('settings_about_tmdb_tile'),
                    title: 'TMDB',
                    subtitle:
                        '${KonataNetworkConfig.tmdbHomeUrl} · This product uses the TMDB API but is not endorsed or certified by TMDB.',
                    leading: _buildLeadingBox(
                      const Text(
                        'TM\nDB',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: KonataTheme.tmdbCyan,
                          fontSize: KonataTheme.fontSizeBadge,
                          height: 1.0,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.4,
                        ),
                      ),
                      backgroundColor: KonataTheme.tmdbCyan.withValues(
                        alpha: 0.14,
                      ),
                    ),
                    trailing: Icon(
                      Icons.chevron_right_rounded,
                      size: 20,
                      color: p.textMuted,
                    ),
                    onTap: () =>
                        effectiveController.openExternalUrl(_tmdbHomeUri),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 标准 GitHub Octocat 章鱼猫矢量图标（基于 24x24 Invertocat 路径绘制）。
class _GitHubOctocatIcon extends StatelessWidget {
  const _GitHubOctocatIcon({required this.color, this.size = 22});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: _OctocatPainter(color),
    );
  }
}

class _OctocatPainter extends CustomPainter {
  const _OctocatPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / 24.0;
    final sy = size.height / 24.0;
    canvas.save();
    canvas.scale(sx, sy);

    final path = Path()
      ..moveTo(12, 0.5)
      ..cubicTo(5.37, 0.5, 0, 5.87, 0, 12.5)
      ..cubicTo(0, 17.81, 3.44, 22.3, 8.21, 23.89)
      ..cubicTo(8.81, 24.0, 9.03, 23.63, 9.03, 23.31)
      ..cubicTo(9.03, 23.02, 9.02, 22.07, 9.02, 21.05)
      ..cubicTo(5.68, 21.77, 4.98, 19.63, 4.98, 19.63)
      ..cubicTo(4.43, 18.24, 3.64, 17.87, 3.64, 17.87)
      ..cubicTo(2.55, 17.13, 3.72, 17.14, 3.72, 17.14)
      ..cubicTo(4.92, 17.23, 5.56, 18.38, 5.56, 18.38)
      ..cubicTo(6.63, 20.22, 8.37, 19.69, 9.06, 19.38)
      ..cubicTo(9.17, 18.6, 9.48, 18.07, 9.82, 17.77)
      ..cubicTo(7.15, 17.47, 4.35, 16.44, 4.35, 11.84)
      ..cubicTo(4.35, 10.53, 4.82, 9.46, 5.58, 8.62)
      ..cubicTo(5.46, 8.32, 5.05, 7.1, 5.7, 5.45)
      ..cubicTo(5.7, 5.45, 6.71, 5.13, 9.0, 6.68)
      ..cubicTo(9.96, 6.41, 10.98, 6.28, 12.0, 6.27)
      ..cubicTo(13.02, 6.28, 14.04, 6.41, 15.0, 6.68)
      ..cubicTo(17.29, 5.13, 18.29, 5.45, 18.29, 5.45)
      ..cubicTo(18.95, 7.1, 18.54, 8.32, 18.42, 8.62)
      ..cubicTo(19.18, 9.46, 19.65, 10.53, 19.65, 11.84)
      ..cubicTo(19.65, 16.45, 16.84, 17.46, 14.17, 17.76)
      ..cubicTo(14.6, 18.13, 14.98, 18.86, 14.98, 19.98)
      ..cubicTo(14.98, 21.58, 14.96, 22.87, 14.96, 23.31)
      ..cubicTo(14.96, 23.63, 15.18, 24.01, 15.79, 23.89)
      ..cubicTo(20.56, 22.3, 24.0, 17.8, 24.0, 12.5)
      ..cubicTo(24.0, 5.87, 18.63, 0.5, 12.0, 0.5)
      ..close();

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    canvas.drawPath(path, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _OctocatPainter oldDelegate) =>
      oldDelegate.color != color;
}
