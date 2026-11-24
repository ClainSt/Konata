import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_design_system/konata_design_system.dart';
import 'package:konata_storage/konata_storage.dart';

import '../data/photos_cleanup_scanner.dart';
import '../providers.dart';
import '../state/settings_controller.dart';
import 'photo_custom_cleanup_dialog.dart';
import 'settings_shared_widgets.dart';

/// 本地图片存储统计清理与脱敏诊断日志导出面板（纯设计系统组件实现）。
class SettingsPhotosStorageCard extends ConsumerWidget {
  /// 创建存储与诊断日志设置卡片。
  const SettingsPhotosStorageCard({super.key, this.controller});

  /// 可选直传设置控制器；为空时从 [settingsControllerProvider] 获取。
  final SettingsController? controller;

  Future<void> _onClearRegenerable(
    BuildContext context,
    SettingsController ctrl,
  ) async {
    final removed = await ctrl.clearRegenerableCaches();
    if (context.mounted) {
      showKonataToast(context, '已清理可再生缓存 $removed 个文件');
    }
  }

  Future<void> _onCustomCleanup(
    BuildContext context,
    SettingsController ctrl,
  ) async {
    final snapshot = ctrl.photosSnapshot ?? await ctrl.refreshPhotosStorage();
    if (!context.mounted) {
      return;
    }
    final choice = await showPhotoCustomCleanupDialog(
      context,
      snapshot: snapshot,
    );
    if (choice == null || choice.categories.isEmpty) {
      return;
    }
    final removed = await ctrl.clearPhotoCategories(
      choice.categories,
      workId: choice.workId,
    );
    if (context.mounted) {
      showKonataToast(context, '已精准清理 $removed 个图片文件');
    }
  }

  Future<void> _onExportDiagnostics(
    BuildContext context,
    SettingsController ctrl, {
    required bool asJson,
  }) async {
    final savedPath = await ctrl.exportDiagnosticBundle(asJson: asJson);
    if (!context.mounted) {
      return;
    }
    if (savedPath == null) {
      showKonataToast(context, '已取消导出诊断报告');
    } else {
      showKonataToast(context, '已导出脱敏诊断报告至：$savedPath');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final direct = controller;
    final SettingsController effectiveController =
        direct ?? ref.watch(settingsControllerProvider);
    final tokens = Theme.of(context).extension<KonataPalette>()!;

    return AnimatedBuilder(
      animation: effectiveController,
      builder: (context, _) {
        final snapshot = effectiveController.photosSnapshot;
        final stats = snapshot?.globalStats;
        final diagCounts = effectiveController.diagnosticCounts;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            KonataSurfaceCard(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SettingsSectionHeader(
                    icon: Icons.storage_rounded,
                    title: '本地图片与缓存占用',
                    subtitle: stats == null
                        ? '正在扫描本地图片目录...'
                        : '根目录：${stats.rootPath}',
                    trailing: KonataPillButton.ghost(
                      label: effectiveController.isScanningPhotos
                          ? '刷新中...'
                          : '重新扫描',
                      icon: Icons.refresh_rounded,
                      compact: true,
                      onPressed: effectiveController.isScanningPhotos
                          ? null
                          : effectiveController.refreshPhotosStorage,
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (stats != null) ...[
                    Row(
                      children: [
                        _MetricTile(
                          label: '总占用空间',
                          value: PhotosCleanupScanner.formatBytes(
                            stats.totalBytes,
                          ),
                          tokens: tokens,
                        ),
                        const SizedBox(width: 12),
                        _MetricTile(
                          label: '图片文件总数',
                          value: '${stats.totalFiles} 张',
                          tokens: tokens,
                        ),
                        const SizedBox(width: 12),
                        _MetricTile(
                          label: '作品目录数',
                          value: '${stats.workFolderCount} 个',
                          tokens: tokens,
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    for (final cat in PhotoStorageCategory.values)
                      _CategoryBreakdownRow(
                        label: cat.displayLabel,
                        stat:
                            stats.byCategory[cat.toSubfolder()] ??
                            PhotoCategoryStat.zero,
                        isRegenerable: cat.isRegenerable,
                        tokens: tokens,
                      ),
                    const SizedBox(height: 14),
                  ],
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    children: [
                      KonataPillButton.primary(
                        label: '清理可再生缩略缓存',
                        icon: Icons.cleaning_services_outlined,
                        compact: true,
                        onPressed: effectiveController.isScanningPhotos
                            ? null
                            : () => _onClearRegenerable(
                                context,
                                effectiveController,
                              ),
                      ),
                      KonataPillButton.secondary(
                        label: '自定义精确清理',
                        icon: Icons.tune_rounded,
                        compact: true,
                        onPressed: effectiveController.isScanningPhotos
                            ? null
                            : () => _onCustomCleanup(
                                context,
                                effectiveController,
                              ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            KonataSurfaceCard(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SettingsSectionHeader(
                    icon: Icons.bug_report_outlined,
                    title: '运行诊断日志与脱敏导出',
                    subtitle: '导出前自动剥离 API 密钥、PAT 凭据与本地用户主目录敏感路径',
                  ),
                  const SizedBox(height: 14),
                  SettingsSwitchTile(
                    title: '记录详细调试事件',
                    subtitle: '开启后保留网络调度与任务细节以便排查疑难故障',
                    value: effectiveController.verboseDiagnosticsEnabled,
                    onChanged: effectiveController.setDiagnosticVerbose,
                  ),
                  const SizedBox(height: 14),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: tokens.softFill,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: tokens.hairline),
                    ),
                    child: Text(
                      '当前累计记录 ${diagCounts.totalEvents} 条事件 · 告警 ${diagCounts.warningCount} 条 · 错误 ${diagCounts.errorCount} 条 · 面包屑 ${diagCounts.breadcrumbCount} 条',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: tokens.textSecondary,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    children: [
                      KonataPillButton.primary(
                        label: effectiveController.isExportingDiagnostics
                            ? '正在脱敏导出...'
                            : '导出脱敏 JSON 诊断包',
                        icon: Icons.download_outlined,
                        compact: true,
                        onPressed: effectiveController.isExportingDiagnostics
                            ? null
                            : () => _onExportDiagnostics(
                                context,
                                effectiveController,
                                asJson: true,
                              ),
                      ),
                      KonataPillButton.secondary(
                        label: '导出脱敏文本报告',
                        icon: Icons.description_outlined,
                        compact: true,
                        onPressed: effectiveController.isExportingDiagnostics
                            ? null
                            : () => _onExportDiagnostics(
                                context,
                                effectiveController,
                                asJson: false,
                              ),
                      ),
                      KonataPillButton.ghost(
                        label: '清空内存日志',
                        icon: Icons.delete_outline_rounded,
                        compact: true,
                        onPressed: () {
                          effectiveController.clearDiagnosticLogs();
                          showKonataToast(context, '已清空运行日志缓存');
                        },
                      ),
                    ],
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

class _MetricTile extends StatelessWidget {
  const _MetricTile({
    required this.label,
    required this.value,
    required this.tokens,
  });

  final String label;
  final String value;
  final KonataPalette tokens;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: tokens.softFill,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: tokens.hairline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(fontSize: 11.5, color: tokens.textSecondary),
            ),
            const SizedBox(height: 4),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14.5,
                fontWeight: FontWeight.w700,
                color: tokens.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CategoryBreakdownRow extends StatelessWidget {
  const _CategoryBreakdownRow({
    required this.label,
    required this.stat,
    required this.isRegenerable,
    required this.tokens,
  });

  final String label;
  final PhotoCategoryStat stat;
  final bool isRegenerable;
  final KonataPalette tokens;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    color: tokens.textPrimary,
                  ),
                ),
                if (isRegenerable) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: tokens.accent.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '可再生',
                      style: TextStyle(fontSize: 10.5, color: tokens.accent),
                    ),
                  ),
                ],
              ],
            ),
          ),
          Text(
            '${stat.files} 个 · ${PhotosCleanupScanner.formatBytes(stat.bytes)}',
            style: TextStyle(fontSize: 12.5, color: tokens.textSecondary),
          ),
        ],
      ),
    );
  }
}
