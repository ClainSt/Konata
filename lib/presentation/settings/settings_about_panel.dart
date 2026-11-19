import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../application/providers/diagnostics_providers.dart';
import '../../domain/models/network_config.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/konata_surface_card.dart';
import '../widgets/design_system/konata_switch.dart';
import '../widgets/design_system/konata_toast.dart';

/// 关于页面板（真实 Konata 头像、版本 1.0.0、调试日志、异常导出、GitHub Octocat 与 TMDB 声明）。
class SettingsAboutPanel extends ConsumerWidget {
  /// 创建关于面板。
  const SettingsAboutPanel({super.key});

  Future<void> _openUrl(String url) async {
    final uri = Uri.parse(url);
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _exportLogs(BuildContext context, WidgetRef ref) async {
    final report =
        ref.read(diagnosticsLogStoreProvider).buildRecentIncidentReport();
    final targetUri = await FilePicker.saveFile(
      dialogTitle: '导出最近异常日志',
      fileName: 'konata_incident_log.txt',
      bytes: Uint8List.fromList(utf8.encode(report)),
    );
    if (targetUri == null) return;

    if (context.mounted) {
      showKonataToast(context, '已导出异常日志至 ${targetUri.toFilePath()}');
    }
  }

  Widget _buildLeadingBox(
    KonataPalette p,
    Widget child, {
    Color? backgroundColor,
  }) {
    return SizedBox(
      width: 38,
      height: 38,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: backgroundColor ?? p.softFill,
          borderRadius: KonataTheme.borderRadiusControl,
          border: Border.all(color: p.hairline, width: 1),
        ),
        child: Center(child: child),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final verboseEnabled = ref.watch(verboseLoggingProvider);

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
                      '版本 1.0.0',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: p.textSecondary, fontSize: KonataTheme.fontSizeBodySm),
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
                subtitle: '平时保留异常和必要的播放记录；复现问题前开启，可补充详细信息。',
                leading: _buildLeadingBox(
                  p,
                  Icon(
                    Icons.bug_report_outlined,
                    size: 20,
                    color: p.textSecondary,
                  ),
                ),
                trailing: KonataSwitch(
                  value: verboseEnabled,
                  onChanged: (value) => ref
                      .read(verboseLoggingProvider.notifier)
                      .setEnabled(value),
                ),
              ),
              Divider(height: 1, color: p.hairline, indent: 18, endIndent: 18),
              KonataListTile(
                title: '导出最近异常日志',
                subtitle: '仅导出最近一次异常前后的 TXT 文本记录',
                leading: _buildLeadingBox(
                  p,
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
                onTap: () => _exportLogs(context, ref),
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
                title: 'ClainSt/Konata',
                subtitle: TmdbNetworkConfig.githubRepoUrl,
                leading: _buildLeadingBox(
                  p,
                  _GitHubOctocatIcon(color: p.textPrimary, size: 22),
                ),
                trailing: Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: p.textMuted,
                ),
                onTap: () => _openUrl(TmdbNetworkConfig.githubRepoUrl),
              ),
              Divider(height: 1, color: p.hairline, indent: 18, endIndent: 18),
              KonataListTile(
                title: 'TMDB',
                subtitle:
                    '${TmdbNetworkConfig.tmdbHomeUrl} · This product uses the TMDB API but is not endorsed or certified by TMDB.',
                leading: _buildLeadingBox(
                  p,
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
                  backgroundColor: KonataTheme.tmdbCyan.withValues(alpha: 0.14),
                ),
                trailing: Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: p.textMuted,
                ),
                onTap: () => _openUrl(TmdbNetworkConfig.tmdbHomeUrl),
              ),
            ],
          ),
        ),
      ],
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
