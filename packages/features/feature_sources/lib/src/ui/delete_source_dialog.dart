import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';

/// 移除媒体源前的安全确认弹窗。
///
/// 明确告知用户「仅从 Konata 索引库移除记录与刮削作品，绝不删除磁盘或网盘上的任何物理媒体文件」。
Future<bool> showDeleteSourceDialog(
  BuildContext context, {
  required MediaSource source,
}) async {
  final result = await showKonataGlassDialog<bool>(
    context: context,
    builder: (dialogCtx) {
      final p = dialogCtx.palette;
      return KonataGlassDialog(
        title: '移除媒体源',
        width: 440,
        actions: [
          KonataPillButton.ghost(
            label: '取消',
            onPressed: () => Navigator.of(dialogCtx).pop(false),
          ),
          KonataPillButton.danger(
            label: '确认移除',
            icon: Icons.delete_outline_rounded,
            onPressed: () => Navigator.of(dialogCtx).pop(true),
          ),
        ],
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '确定要移除媒体源「${source.label}」吗？',
              style: TextStyle(
                fontSize: 14.5,
                fontWeight: FontWeight.w600,
                color: p.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              source.location,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                color: p.textMuted,
              ),
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: p.softFill,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: p.hairline),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.shield_outlined,
                    size: 18,
                    color: p.accent,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '仅删除本地媒体库中的索引与已关联凭据，绝不会修改或删除磁盘 / WebDAV / SMB 上的任何物理视频与文件。',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: p.textSecondary,
                        height: 1.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
  return result ?? false;
}
