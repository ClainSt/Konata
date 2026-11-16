import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../application/providers/library_providers.dart';
import '../../domain/formatting/media_display_formatter.dart';
import '../../infrastructure/cache/photos_storage.dart';
import '../theme/konata_palette.dart';
import '../widgets/design_system/ellipsis_text_with_tooltip.dart';
import '../widgets/design_system/konata_pill_button.dart';
import '../widgets/design_system/konata_surface_card.dart';
import '../widgets/design_system/konata_toast.dart';

/// 外观与显示页底部的统一 `photos/` 图片存储管理卡片：
/// 展示根目录路径、五类图片分项占用统计，并支持打开存储目录与一键清理可再生微缩图缓存。
class SettingsPhotosStorageCard extends ConsumerStatefulWidget {
  /// 创建图片存储管理卡片。
  const SettingsPhotosStorageCard({super.key});

  @override
  ConsumerState<SettingsPhotosStorageCard> createState() =>
      _SettingsPhotosStorageCardState();
}

class _SettingsPhotosStorageCardState
    extends ConsumerState<SettingsPhotosStorageCard> {
  PhotosStorageStats? _stats;
  bool _loading = false;
  bool _clearing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refreshStats());
  }

  Future<void> _refreshStats() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final storage = ref.read(photosStorageProvider);
      final stats = await storage.computeStats();
      if (!mounted) return;
      setState(() {
        _stats = stats;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _openPhotosFolder() async {
    final storage = ref.read(photosStorageProvider);
    final dir = storage.resolveRootDirectory();
    try {
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final ok = await launchUrl(
        Uri.file(dir.path),
        mode: LaunchMode.externalApplication,
      );
      if (!ok && mounted) {
        showKonataToast(context, '无法打开本地图片目录');
      }
    } catch (err) {
      if (mounted) {
        showKonataToast(context, '打开目录失败: $err');
      }
    }
  }

  Future<void> _clearRegenerableCache() async {
    if (_clearing) return;
    setState(() => _clearing = true);
    try {
      final storage = ref.read(photosStorageProvider);
      final cleared = await storage.clearRegenerableCache();
      final nextStats = await storage.computeStats();
      if (!mounted) return;
      setState(() {
        _stats = nextStats;
        _clearing = false;
      });
      if (cleared.deletedFiles == 0) {
        showKonataToast(context, '当前暂无可清理的微缩图缓存');
      } else {
        showKonataToast(
          context,
          '已清理 ${cleared.deletedFiles} 张可再生微缩图，释放 '
          '${MediaDisplayFormatter.formatBytes(cleared.deletedBytes, emptyFallback: '0 B')}',
        );
      }
    } catch (err) {
      if (!mounted) return;
      setState(() => _clearing = false);
      showKonataToast(context, '清理微缩图缓存失败: $err');
    }
  }

  static String _categoryTitle(PhotoSubfolder sub) {
    return switch (sub) {
      PhotoSubfolder.posters => '封面海报 (posters)',
      PhotoSubfolder.backdrops => '背景原画 (backdrops)',
      PhotoSubfolder.logos => '标题徽标 (logos)',
      PhotoSubfolder.thumbnails => '分集剧照 (thumbnails)',
      PhotoSubfolder.scans => 'Scan 微缩图 (scans)',
    };
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final storage = ref.watch(photosStorageProvider);
    final stats = _stats;
    final rootPath = stats?.rootPath ?? storage.resolveRootDirectory().path;
    final regenerableBytes = stats?.regenerableBytes ?? 0;
    final regenerableFiles = stats?.regenerableFiles ?? 0;

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
                  label: _loading ? '统计中...' : '刷新',
                  icon: Icons.refresh_rounded,
                  compact: true,
                  onPressed: _loading ? null : _refreshStats,
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
                        regenerable:
                            sub == PhotoSubfolder.scans ||
                            sub == PhotoSubfolder.thumbnails,
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
                        style: TextStyle(color: p.textMuted, fontSize: 12),
                      ),
                    ),
                    const SizedBox(width: 12),
                    KonataPillButton.secondary(
                      label: '打开 photos 文件夹',
                      icon: Icons.folder_open_rounded,
                      compact: true,
                      onPressed: _openPhotosFolder,
                    ),
                    const SizedBox(width: 8),
                    KonataPillButton.secondary(
                      label: _clearing ? '清理中...' : '清理可再生微缩图',
                      icon: Icons.cleaning_services_outlined,
                      compact: true,
                      onPressed: (_clearing || (stats != null && regenerableFiles == 0))
                          ? null
                          : _clearRegenerableCache,
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
    required this.regenerable,
  });

  final String label;
  final PhotoCategoryStat? stat;
  final bool regenerable;

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
        border: Border.all(
          color: regenerable ? p.accent.withValues(alpha: 0.28) : p.hairline,
        ),
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
            ),
          ),
        ],
      ),
    );
  }
}
