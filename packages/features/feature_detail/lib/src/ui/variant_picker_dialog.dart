import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/media_display_formatter.dart';

/// 单集存在多压制组或清晰度物理版本时的播放版本选择弹窗。
class VariantPickerDialog extends StatelessWidget {
  /// 创建多版本选择播放弹窗。
  const VariantPickerDialog({
    super.key,
    required this.episodeTitle,
    required this.variants,
    required this.sourcesById,
    required this.onSelectVariant,
  });

  /// 剧集标题。
  final String episodeTitle;

  /// 可选物理版本列表。
  final List<MediaVariant> variants;

  /// 媒体源索引映射。
  final Map<String, MediaSource> sourcesById;

  /// 选中特定版本后触发播放的回调。
  final ValueChanged<MediaVariant> onSelectVariant;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return KonataGlassDialog(
      width: 520,
      maxHeight: 480,
      title: '选择播放版本 · $episodeTitle',
      onClose: () => Navigator.of(context).pop(),
      actions: [
        KonataPillButton.ghost(
          label: '取消',
          compact: true,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
      child: KonataDraggableScrollbar(
        builder: (_, controller) => ListView.separated(
          controller: controller,
          shrinkWrap: true,
          itemCount: variants.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (_, index) {
            final variant = variants[index];
            final source = sourcesById[variant.sourceId];
            final title = MediaDisplayFormatter.formatVariantDisplayLabel(
              variant,
              source: source,
            );
            final tags = MediaDisplayFormatter.buildVariantTechTags(variant);
            final sizeLabel = variant.fileSize > 0
                ? MediaDisplayFormatter.formatBytes(variant.fileSize)
                : '';

            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                Navigator.of(context).pop();
                onSelectVariant(variant);
              },
              child: KonataSurfaceCard(
                enableHover: true,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: KonataTheme.cardTitleStyle(
                              p,
                              fontSize: KonataTheme.fontSizeBody,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            variant.fileName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: KonataTheme.captionStyle(
                              p,
                            ).copyWith(color: p.textSecondary),
                          ),
                          if (tags.isNotEmpty || sizeLabel.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                for (final tag in tags)
                                  KonataSpecBadge(label: tag),
                                if (sizeLabel.isNotEmpty)
                                  KonataSpecBadge(label: sizeLabel),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    KonataPillButton.secondary(
                      label: '播放',
                      icon: Icons.play_arrow_rounded,
                      compact: true,
                      onPressed: () {
                        Navigator.of(context).pop();
                        onSelectVariant(variant);
                      },
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
