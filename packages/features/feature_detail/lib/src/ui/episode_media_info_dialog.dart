import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/media_display_formatter.dart';

/// 展示指定剧集关联物理版本技术规格、文件路径与音视频参数详情的弹窗。
class EpisodeMediaInfoDialog extends StatelessWidget {
  /// 创建剧集媒体信息弹窗。
  const EpisodeMediaInfoDialog({
    super.key,
    required this.episodeTitle,
    required this.variants,
    required this.sourcesById,
    this.onRevealSource,
  });

  /// 剧集主展示标题。
  final String episodeTitle;

  /// 该剧集关联的全部物理版本列表。
  final List<MediaVariant> variants;

  /// 已索引的媒体源映射表。
  final Map<String, MediaSource> sourcesById;

  /// 可选打开文件目录或查看源路径回调。
  final ValueChanged<MediaVariant>? onRevealSource;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return KonataGlassDialog(
      width: 560,
      maxHeight: 520,
      title: '媒体文件信息 · $episodeTitle',
      onClose: () => Navigator.of(context).pop(),
      actions: [
        KonataPillButton.primary(
          label: '关闭',
          compact: true,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
      child: variants.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 28),
              child: Center(
                child: Text(
                  '暂无关联的物理媒体文件信息',
                  style: KonataTheme.bodyLabelStyle(p).copyWith(color: p.textSecondary),
                ),
              ),
            )
          : KonataDraggableScrollbar(
              builder: (_, controller) => ListView.separated(
                controller: controller,
                shrinkWrap: true,
                itemCount: variants.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (_, index) {
                  final variant = variants[index];
                  final source = sourcesById[variant.sourceId];
                  final sourceKind = source != null
                      ? MediaDisplayFormatter.formatSourceKindShort(source.kind)
                      : '未知来源';
                  final sourceName = source?.label.trim().isNotEmpty == true
                      ? source!.label.trim()
                      : sourceKind;
                  final techTags = MediaDisplayFormatter.buildVariantTechTags(
                    variant,
                  );
                  final fileSizeLabel = variant.fileSize > 0
                      ? MediaDisplayFormatter.formatBytes(variant.fileSize)
                      : '';
                  final fullPath = variant.relativePath.trim().isNotEmpty
                      ? variant.relativePath
                      : variant.fileName;

                  return KonataSurfaceCard(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: SelectableText(
                                variant.fileName,
                                style: KonataTheme.cardTitleStyle(
                                  p,
                                  fontSize: KonataTheme.fontSizeBody,
                                ),
                              ),
                            ),
                            if (fileSizeLabel.isNotEmpty) ...[
                              const SizedBox(width: 8),
                              KonataSpecBadge(label: fileSizeLabel),
                            ],
                          ],
                        ),
                        if (techTags.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (final tag in techTags)
                                KonataSpecBadge(label: tag),
                            ],
                          ),
                        ],
                        const SizedBox(height: 10),
                        _MediaInfoFieldRow(
                          label: '所属媒体源',
                          value: '$sourceName ($sourceKind)',
                        ),
                        const SizedBox(height: 4),
                        _MediaInfoFieldRow(
                          label: '相对路径',
                          value: fullPath,
                          selectable: true,
                        ),
                        if (variant.releaseGroup?.trim().isNotEmpty ?? false) ...[
                          const SizedBox(height: 4),
                          _MediaInfoFieldRow(
                            label: '压制/发布组',
                            value: variant.releaseGroup!.trim(),
                          ),
                        ],
                        if (variant.subtitleGroup?.trim().isNotEmpty ?? false) ...[
                          const SizedBox(height: 4),
                          _MediaInfoFieldRow(
                            label: '字幕组',
                            value: variant.subtitleGroup!.trim(),
                          ),
                        ],
                        if (onRevealSource != null) ...[
                          const SizedBox(height: 10),
                          Align(
                            alignment: Alignment.centerRight,
                            child: KonataPillButton.ghost(
                              label: '定位源目录',
                              icon: Icons.folder_open_rounded,
                              compact: true,
                              onPressed: () => onRevealSource!(variant),
                            ),
                          ),
                        ],
                      ],
                    ),
                  );
                },
              ),
            ),
    );
  }
}

class _MediaInfoFieldRow extends StatelessWidget {
  const _MediaInfoFieldRow({
    required this.label,
    required this.value,
    this.selectable = false,
  });

  final String label;
  final String value;
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final labelStyle = KonataTheme.captionStyle(
      p,
    ).copyWith(color: p.textMuted);
    final valueStyle = KonataTheme.captionStyle(
      p,
    ).copyWith(color: p.textSecondary);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 78, child: Text(label, style: labelStyle)),
        Expanded(
          child: selectable
              ? SelectableText(value, style: valueStyle)
              : Text(value, style: valueStyle),
        ),
      ],
    );
  }
}
