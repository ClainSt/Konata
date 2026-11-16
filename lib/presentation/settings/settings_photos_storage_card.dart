import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../application/providers/library_providers.dart';
import '../../domain/formatting/media_display_formatter.dart';
import '../../infrastructure/cache/photos_storage.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_playback_tokens.dart';
import '../widgets/design_system/ellipsis_text_with_tooltip.dart';
import '../widgets/design_system/konata_pill_button.dart';
import '../widgets/design_system/konata_surface_card.dart';
import '../widgets/design_system/konata_toast.dart';
import 'photo_custom_cleanup_dialog.dart';

/// 外观与显示页底部的统一 `photos/` 图片存储管理卡片：
/// 展示根目录路径、五类图片分项占用统计，并支持打开存储目录与按「作品 × 分类」自定义清理。
class SettingsPhotosStorageCard extends ConsumerWidget {
  /// 创建图片存储管理卡片。
  const SettingsPhotosStorageCard({super.key});

  Future<void> _openPhotosFolder(
    BuildContext context,
    PhotosStorage storage,
  ) async {
    final dir = storage.resolveRootDirectory();
    try {
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final ok = await launchUrl(
        Uri.file(dir.path),
        mode: LaunchMode.externalApplication,
      );
      if (!ok && context.mounted) {
        showKonataToast(context, '无法打开本地图片目录');
      }
    } catch (err) {
      if (context.mounted) {
        showKonataToast(context, '打开目录失败: $err');
      }
    }
  }

  static String _categoryTitle(PhotoSubfolder sub) {
    return switch (sub) {
      PhotoSubfolder.posters => PhotoStorageCategory.posters.displayLabel,
      PhotoSubfolder.backdrops => PhotoStorageCategory.backdrops.displayLabel,
      PhotoSubfolder.logos => PhotoStorageCategory.logos.displayLabel,
      PhotoSubfolder.thumbnails => PhotoStorageCategory.thumbnails.displayLabel,
      PhotoSubfolder.scans => PhotoStorageCategory.scans.displayLabel,
    };
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final storage = ref.watch(photosStorageProvider);
    final snapshotAsync = ref.watch(photosStorageSnapshotProvider);
    final snapshot = snapshotAsync.valueOrNull;
    final stats = snapshot?.stats;
    final loading = snapshotAsync.isLoading || snapshotAsync.isRefreshing;
    final rootPath = stats?.rootPath ?? storage.resolveRootDirectory().path;
    final regenerableBytes = stats?.regenerableBytes ?? 0;
    final regenerableFiles = stats?.regenerableFiles ?? 0;
    final canCustomizeClean =
        snapshot != null &&
        (snapshot.libraryWorkCount > 0 || (stats?.totalFiles ?? 0) > 0);

    return KonataSurfaceCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '本地图片存储 (photos/)',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '全站海报、背景原画与 Scan `.webp` 微缩图均按作品目录就近存放，零写入系统盘或临时目录',
                        style: TextStyle(color: p.textSecondary, fontSize: 12.5),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                KonataPillButton.ghost(
                  label: loading ? '统计中...' : '刷新',
                  icon: Icons.refresh_rounded,
                  compact: true,
                  onPressed: loading
                      ? null
                      : () => ref.invalidate(photosStorageSnapshotProvider),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 9,
                  ),
                  decoration: BoxDecoration(
                    color: p.softFill,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: p.hairline),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.folder_outlined,
                        size: 16,
                        color: p.textSecondary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: EllipsisTextWithTooltip(
                          text: rootPath,
                          maxLines: 1,
                          style: TextStyle(
                            color: p.textPrimary,
                            fontSize: 12.5,
                            fontFamily: 'Consolas',
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        stats == null
                            ? '--'
                            : '${stats.workFolderCount} 部作品 · '
                                  '${stats.totalFiles} 张 · '
                                  '${MediaDisplayFormatter.formatBytes(stats.totalBytes, emptyFallback: '0 B')}',
                        style: TextStyle(
                          color: p.textSecondary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          fontFeatures: KonataPlaybackTokens.tabularNumbers,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final sub in PhotoSubfolder.values)
                      _CategoryStatChip(
                        label: _categoryTitle(sub),
                        stat: stats?.byCategory[sub],
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '可再生缓存 (scans + thumbnails)：'
                        '${MediaDisplayFormatter.formatBytes(regenerableBytes, emptyFallback: '0 B')}'
                        '（$regenerableFiles 张）',
                        style: TextStyle(
                          color: p.textMuted,
                          fontSize: 12,
                          fontFeatures: KonataPlaybackTokens.tabularNumbers,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    KonataPillButton.secondary(
                      label: '打开 photos 文件夹',
                      icon: Icons.folder_open_rounded,
                      compact: true,
                      onPressed: () =>
                          unawaited(_openPhotosFolder(context, storage)),
                    ),
                    const SizedBox(width: 8),
                    KonataPillButton.secondary(
                      label: '自定义清理',
                      icon: Icons.cleaning_services_outlined,
                      compact: true,
                      onPressed: canCustomizeClean
                          ? () => unawaited(
                              showPhotoCustomCleanupDialog(context),
                            )
                          : null,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CategoryStatChip extends StatelessWidget {
  const _CategoryStatChip({
    required this.label,
    required this.stat,
  });

  final String label;
  final PhotoCategoryStat? stat;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final bytes = stat?.bytes ?? 0;
    final files = stat?.files ?? 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
      decoration: BoxDecoration(
        color: p.softFill,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: p.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              color: p.textSecondary,
              fontSize: 11.5,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '${MediaDisplayFormatter.formatBytes(bytes, emptyFallback: '0 B')} · $files 张',
            style: TextStyle(
              color: p.textPrimary,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              fontFeatures: KonataPlaybackTokens.tabularNumbers,
            ),
          ),
        ],
      ),
    );
  }
}
