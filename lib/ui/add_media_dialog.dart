import '../l10n/strings.dart';
import 'package:flutter/material.dart';

/// NipaPlay-style category chooser; only implemented source types are shown.
class AddMediaDialog extends StatelessWidget {
  const AddMediaDialog({super.key});
  static Future<String?> show(BuildContext context) => showDialog<String>(
    context: context,
    builder: (_) => const AddMediaDialog(),
  );

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Row(
      children: [
        Expanded(child: Text(context.l10n.addMedia)),
        IconButton(
          tooltip: context.l10n.closeWindow,
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.close),
        ),
      ],
    ),
    content: SizedBox(
      width: 640,
      child: SingleChildScrollView(
        child: LayoutBuilder(
          builder: (context, bounds) {
            final cardWidth = bounds.maxWidth >= 520
                ? (bounds.maxWidth - 16) / 2
                : bounds.maxWidth;
            Widget card(
              String kind,
              String title,
              String subtitle,
              IconData icon,
              Color color,
            ) => SizedBox(
              width: cardWidth,
              child: Card(
                margin: EdgeInsets.zero,
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => Navigator.pop(context, kind),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 22,
                    ),
                    child: Row(
                      children: [
                        Icon(icon, color: color, size: 32),
                        const SizedBox(width: 18),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                subtitle,
                                style: TextStyle(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurface.withValues(alpha: .6),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Icon(Icons.chevron_right, color: Colors.grey),
                      ],
                    ),
                  ),
                ),
              ),
            );
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  context.l10n.localMedia,
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 16),
                card(
                  'local',
                  context.l10n.localFolder,
                  context.l10n.addLocalFolder,
                  Icons.folder_outlined,
                  const Color(0xffffb74d),
                ),
                const SizedBox(height: 28),
                Text(
                  context.l10n.networkMedia,
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 16,
                  runSpacing: 16,
                  children: [
                    card(
                      'webdav',
                      'WebDAV',
                      context.l10n.addWebdav,
                      Icons.cloud_outlined,
                      const Color(0xff64b5f6),
                    ),
                    card(
                      'smb',
                      'SMB',
                      context.l10n.addSmb,
                      Icons.account_tree_outlined,
                      const Color(0xff66bb6a),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    ),
  );
}
