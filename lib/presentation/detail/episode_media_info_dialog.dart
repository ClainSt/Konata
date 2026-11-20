import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/formatting/media_display_formatter.dart';
import '../../domain/models/episode.dart';
import '../../domain/models/media_source.dart';
import '../../domain/models/media_variant.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/konata_draggable_scrollbar.dart';
import '../widgets/design_system/konata_glass_dialog.dart';
import '../widgets/design_system/konata_pill_button.dart';
import '../widgets/design_system/konata_segmented_capsule.dart';
import '../widgets/design_system/konata_surface_card.dart';
import '../widgets/design_system/konata_toast.dart';

/// 剧集媒体信息只读弹窗（通过右键或长按菜单触发，零缩略图遮挡）。
///
/// 完整展示单集关联的物理文件规格、媒体源归属、压制/字幕组与外挂字幕清单，
/// 支持多版本切换查看并一键复制相对路径。
class EpisodeMediaInfoDialog extends StatefulWidget {
  /// 创建剧集媒体信息弹窗。
  const EpisodeMediaInfoDialog({
    super.key,
    required this.episode,
    required this.displayTitle,
    required this.variants,
    required this.sourcesById,
  });

  /// 目标逻辑剧集。
  final Episode episode;

  /// 已格式化的展示标题。
  final String displayTitle;

  /// 关联的物理媒体版本列表。
  final List<MediaVariant> variants;

  /// 媒体源查找表。
  final Map<String, MediaSource> sourcesById;

  /// 以全站统一毛玻璃弹窗形式打开媒体信息面板。
  static Future<void> show(
    BuildContext context, {
    required Episode episode,
    required String displayTitle,
    required List<MediaVariant> variants,
    required Map<String, MediaSource> sourcesById,
  }) {
    return showKonataGlassDialog<void>(
      context: context,
      builder: (_) => EpisodeMediaInfoDialog(
        episode: episode,
        displayTitle: displayTitle,
        variants: variants,
        sourcesById: sourcesById,
      ),
    );
  }

  @override
  State<EpisodeMediaInfoDialog> createState() => _EpisodeMediaInfoDialogState();
}

class _EpisodeMediaInfoDialogState extends State<EpisodeMediaInfoDialog> {
  final ScrollController _scrollController = ScrollController();
  int _selectedVariantIndex = 0;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  String _sourceKindLabel(MediaSourceKind kind) => switch (kind) {
    MediaSourceKind.local => '本地磁盘',
    MediaSourceKind.webdav => 'WebDAV',
    MediaSourceKind.smb => 'SMB 局域网',
  };

  Future<void> _copyText(String text, String label) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    showKonataToast(context, '已复制$label');
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final variants = widget.variants;
    final safeIdx = variants.isEmpty
        ? 0
        : _selectedVariantIndex.clamp(0, variants.length - 1);
    final variant = variants.isEmpty ? null : variants[safeIdx];
    final source = variant != null ? widget.sourcesById[variant.sourceId] : null;
    final screenH = MediaQuery.sizeOf(context).height;
    final maxBodyHeight = (screenH * 0.58).clamp(240.0, 520.0);

    return KonataGlassDialog(
      width: 560,
      title: '媒体信息 · ${widget.displayTitle}',
      onClose: () => Navigator.of(context).pop(),
      actions: [
        if (variant != null)
          KonataPillButton.secondary(
            label: '复制路径',
            icon: Icons.content_copy_rounded,
            compact: true,
            onPressed: () => _copyText(variant.relativePath, '文件路径'),
          ),
        KonataPillButton.primary(
          label: '关闭',
          compact: true,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
      child: variant == null
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text(
                  '当前剧集暂无关联物理文件',
                  style: KonataTheme.captionStyle(p, color: p.textSecondary),
                ),
              ),
            )
          : ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxBodyHeight),
              child: KonataDraggableScrollbar(
                controller: _scrollController,
                builder: (_, ctrl) => SingleChildScrollView(
                  controller: ctrl,
                  padding: const EdgeInsets.only(right: 12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (variants.length >= 2) ...[
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: KonataSegmentedCapsule<int>(
                            options: [
                              for (var i = 0; i < variants.length; i++)
                                KonataSegmentOption<int>(
                                  value: i,
                                  label: _variantTabLabel(variants[i], i),
                                ),
                            ],
                            selected: safeIdx,
                            onChanged: (idx) =>
                                setState(() => _selectedVariantIndex = idx),
                          ),
                        ),
                        const SizedBox(height: 14),
                      ],
                      _buildSpecBadges(p, variant),
                      const SizedBox(height: 12),
                      KonataSurfaceCard(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _InfoRow(label: '文件名', value: variant.fileName),
                            _InfoRow(
                              label: '相对路径',
                              value: variant.relativePath,
                            ),
                            _InfoRow(
                              label: '文件体积',
                              value: variant.fileSize > 0
                                  ? MediaDisplayFormatter.formatBytes(
                                      variant.fileSize,
                                    )
                                  : '未知',
                            ),
                            if (source != null)
                              _InfoRow(
                                label: '所属媒体源',
                                value:
                                    '${source.label}（${_sourceKindLabel(source.kind)}）',
                              ),
                            if (variant.releaseGroup != null &&
                                variant.releaseGroup!.trim().isNotEmpty)
                              _InfoRow(
                                label: '压制组',
                                value: variant.releaseGroup!.trim(),
                              ),
                            if (variant.subtitleGroup != null &&
                                variant.subtitleGroup!.trim().isNotEmpty)
                              _InfoRow(
                                label: '字幕组',
                                value: variant.subtitleGroup!.trim(),
                              ),
                            _InfoRow(
                              label: '视频轨道',
                              value: _formatVideoTrack(variant),
                            ),
                            _InfoRow(
                              label: '音频轨道',
                              value:
                                  (variant.audioCodec != null &&
                                      variant.audioCodec!.trim().isNotEmpty)
                                  ? variant.audioCodec!.trim()
                                  : '未解析',
                              isLast: true,
                            ),
                          ],
                        ),
                      ),
                      if (variant.externalSubtitles.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        KonataSurfaceCard(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '关联外挂字幕（${variant.externalSubtitles.length}）',
                                style: TextStyle(
                                  color: p.textPrimary,
                                  fontSize: KonataTheme.fontSizeBodySm,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 8),
                              for (
                                var i = 0;
                                i < variant.externalSubtitles.length;
                                i++
                              ) ...[
                                if (i > 0)
                                  Divider(height: 10, color: p.hairline),
                                SelectableText(
                                  variant.externalSubtitles[i],
                                  style: TextStyle(
                                    color: p.textSecondary,
                                    fontSize: KonataTheme.fontSizeCaption,
                                    height: 1.35,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  String _variantTabLabel(MediaVariant v, int index) {
    final group = v.releaseGroup?.trim();
    final res = v.resolution?.trim();
    final parts = <String>[
      if (group != null && group.isNotEmpty) group,
      if (res != null && res.isNotEmpty) res,
    ];
    return parts.isEmpty ? '版本 ${index + 1}' : parts.join(' · ');
  }

  String _formatVideoTrack(MediaVariant v) {
    final parts = <String>[
      if (v.resolution != null && v.resolution!.trim().isNotEmpty)
        v.resolution!.trim(),
      if (v.videoCodec != null && v.videoCodec!.trim().isNotEmpty)
        v.videoCodec!.trim(),
      if (v.bitDepth != null && v.bitDepth!.trim().isNotEmpty)
        v.bitDepth!.trim(),
    ];
    return parts.isEmpty ? '未解析' : parts.join(' · ');
  }

  Widget _buildSpecBadges(KonataPalette p, MediaVariant v) {
    final ext = MediaDisplayFormatter.fileExtensionUpper(v.fileName);
    final chips = <String>[
      if (v.resolution != null && v.resolution!.trim().isNotEmpty)
        v.resolution!.trim(),
      if (v.videoCodec != null && v.videoCodec!.trim().isNotEmpty)
        v.videoCodec!.trim(),
      if (v.bitDepth != null && v.bitDepth!.trim().isNotEmpty)
        v.bitDepth!.trim(),
      if (v.audioCodec != null && v.audioCodec!.trim().isNotEmpty)
        v.audioCodec!.trim(),
      if (ext.isNotEmpty) ext,
    ];
    if (chips.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        for (final chip in chips)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3.5),
            decoration: BoxDecoration(
              color: p.softFill,
              borderRadius: KonataTheme.borderRadiusChip,
              border: Border.all(color: p.hairline, width: 0.9),
            ),
            child: Text(
              chip,
              style: TextStyle(
                color: p.textPrimary,
                fontSize: KonataTheme.fontSizeCaptionSm,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.label,
    required this.value,
    this.isLast = false,
  });

  final String label;
  final String value;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: EdgeInsets.only(bottom: isLast ? 0 : 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 84,
            child: Text(
              label,
              style: TextStyle(
                color: p.textMuted,
                fontSize: KonataTheme.fontSizeCaption,
                fontWeight: FontWeight.w500,
                height: 1.4,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: SelectableText(
              value,
              style: TextStyle(
                color: p.textPrimary,
                fontSize: KonataTheme.fontSizeBodyXs,
                fontWeight: FontWeight.w500,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
