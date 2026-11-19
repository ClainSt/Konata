import 'package:flutter/material.dart';

import '../../domain/models/media_source.dart';
import '../theme/konata_palette.dart';
import '../widgets/design_system/konata_glass_dialog.dart';
import '../widgets/design_system/konata_pill_button.dart';
import '../theme/konata_theme.dart';

/// 删除媒体源毛玻璃二次确认弹窗：明确提示绝不删物理文件，仅清空关联索引与安全凭据。
Future<bool> showDeleteSourceConfirmDialog(
  BuildContext context,
  MediaSource source,
) async {
  final result = await showKonataGlassDialog<bool>(
    context: context,
    builder: (ctx) {
      final p = ctx.palette;
      return KonataGlassDialog(
        title: '移除媒体源「${source.label}」？',
        width: 440,
        actions: [
          KonataPillButton.ghost(
            label: '取消',
            compact: true,
            onPressed: () => Navigator.of(ctx).pop(false),
          ),
          KonataPillButton.primary(
            label: '确认移除索引',
            compact: true,
            onPressed: () => Navigator.of(ctx).pop(true),
          ),
        ],
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: p.softFill,
                borderRadius: KonataTheme.borderRadiusControl,
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
                      '安全承诺：移除操作仅清除 Konata 数据库中的该媒体源配置、刮削索引记录与已保存登录密码，绝对不会删除磁盘或远程服务器上的任何原始视频与字幕文件。',
                      style: TextStyle(
                        fontSize: KonataTheme.fontSizeBodySm,
                        height: 1.5,
                        color: p.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '目标地址：${source.location}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: KonataTheme.fontSizeCaption, color: p.textMuted),
            ),
          ],
        ),
      );
    },
  );
  return result == true;
}
