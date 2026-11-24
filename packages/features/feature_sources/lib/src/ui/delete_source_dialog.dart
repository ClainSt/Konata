import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';

/// 移除媒体源毛玻璃二次确认弹窗：明确提示绝不删物理文件，仅清空关联索引与安全凭据。
Future<bool> showDeleteSourceDialog(
  BuildContext context, {
  required MediaSource source,
}) async {
  final result = await showKonataGlassDialog<bool>(
    context: context,
    builder: (dialogCtx) {
      final p = dialogCtx.palette;
      return KonataGlassDialog(
        title: '移除媒体源「${source.label}」？',
        width: 440,
        actions: [
          KonataPillButton.ghost(
            label: '取消',
            compact: true,
            onPressed: () => Navigator.of(dialogCtx).pop(false),
          ),
          KonataPillButton.danger(
            label: '确认移除索引',
            icon: Icons.delete_outline_rounded,
            compact: true,
            onPressed: () => Navigator.of(dialogCtx).pop(true),
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
              style: TextStyle(
                fontSize: KonataTheme.fontSizeCaption,
                color: p.textMuted,
              ),
            ),
          ],
        ),
      );
    },
  );
  return result == true;
}
