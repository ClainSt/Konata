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
        const Expanded(child: Text('添加媒体')),
        IconButton(
          tooltip: '关闭',
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
                const Text(
                  '本地媒体',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 16),
                card(
                  'local',
                  '本地文件夹',
                  '添加本地媒体文件夹',
                  Icons.folder_outlined,
                  const Color(0xffffb74d),
                ),
                const SizedBox(height: 28),
                const Text(
                  '网络媒体',
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
                      '添加 WebDAV 服务器',
                      Icons.cloud_outlined,
                      const Color(0xff64b5f6),
                    ),
                    card(
                      'smb',
                      'SMB',
                      '添加 SMB 共享',
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
