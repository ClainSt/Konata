import '../l10n/strings.dart';
import 'package:flutter/material.dart';
import '../core/media_version.dart';

class MediaVersionPicker extends StatelessWidget {
  const MediaVersionPicker({
    super.key,
    required this.versions,
    required this.sourceLabels,
  });
  final List<Map<String, Object?>> versions;
  final Map<String, String> sourceLabels;

  static Future<Map<String, Object?>?> choose(
    BuildContext context,
    List<Map<String, Object?>> versions, {
    Map<String, String> sourceLabels = const {},
  }) async {
    if (versions.isEmpty) return null;
    if (versions.length == 1) return versions.single;
    return showModalBottomSheet<Map<String, Object?>>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) =>
          MediaVersionPicker(versions: versions, sourceLabels: sourceLabels),
    );
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .8,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    context.l10n.chooseVersion,
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  tooltip: context.l10n.closeVersion,
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Text(
              context.l10n.filenameHints,
              style: TextStyle(fontSize: 13),
            ),
          ),
          Expanded(
            child: ListView.separated(
              itemCount: versions.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final asset = versions[index];
                final filename =
                    asset['name']?.toString() ??
                    asset['relative_path']?.toString() ??
                    '';
                final metadata = MediaVersion.parse(filename);
                final source =
                    sourceLabels[asset['source_id']?.toString()] ??
                    context.l10n.unknownSource;
                final size = MediaVersion.fileSize(asset['size']);
                return ListTile(
                  key: ValueKey('media-version-${asset['id'] ?? index}'),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                  title: Text(
                    filename,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final tag in metadata.releaseTags)
                          Text('${context.l10n.releaseTag}：$tag'),
                        for (final tag in metadata.encoderTags)
                          Text('${context.l10n.encoderTag}：$tag'),
                        for (final tag in metadata.subtitleGroups)
                          Text('${context.l10n.subtitleGroupTag}：$tag'),
                        if (metadata.technicalLabels.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                for (final rawLabel in metadata.technicalLabels)
                                  DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .primary
                                          .withValues(alpha: .10),
                                      borderRadius: BorderRadius.circular(5),
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 4,
                                      ),
                                      child: Text(switch (rawLabel) {
                                        '简体字幕标记' =>
                                          context.l10n.subtitleSimplified,
                                        '繁體字幕標記' =>
                                          context.l10n.subtitleTraditional,
                                        '中日字幕标记' =>
                                          context.l10n.subtitleBilingual,
                                        'ASS 标记' => context.l10n.subtitleAss,
                                        'PGS 标记' => context.l10n.subtitlePgs,
                                        _ => rawLabel,
                                      }),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        Text(
                          '${context.l10n.sourceLabel}：$source${size == null ? '' : ' · $size'}',
                        ),
                        const SizedBox(height: 4),
                        Text(
                          asset['relative_path']?.toString() ?? '',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  onTap: () => Navigator.pop(context, asset),
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}
