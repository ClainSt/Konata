import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';

/// 移除作品确认结果。
class DeleteWorkConfirmResult {
  /// 创建移除作品确认选项。
  const DeleteWorkConfirmResult({
    required this.ignoreFolderOnRescan,
  });

  /// 是否同步将该作品所属媒体源相对目录加入忽略清单。
  final bool ignoreFolderOnRescan;
}

/// 弹出软删除作品确认弹窗；取消时返回 `null`。
///
/// 向用户明确说明「只删除媒体库索引记录和本机 `photos/` 艺术图缓存，绝不删除媒体源物理视频文件」。
Future<DeleteWorkConfirmResult?> showDeleteWorkDialog(
  BuildContext context, {
  required Work work,
}) {
  return showKonataGlassDialog<DeleteWorkConfirmResult>(
    context: context,
    builder: (_) => _DeleteWorkDialog(work: work),
  );
}

class _DeleteWorkDialog extends StatefulWidget {
  const _DeleteWorkDialog({required this.work});

  final Work work;

  @override
  State<_DeleteWorkDialog> createState() => _DeleteWorkDialogState();
}

class _DeleteWorkDialogState extends State<_DeleteWorkDialog> {
  bool _ignoreFolder = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    return KonataGlassDialog(
      title: '从媒体库移除作品',
      width: 450,
      actions: [
        KonataPillButton.ghost(
          label: '取消',
          onPressed: () => Navigator.of(context).pop(),
        ),
        KonataPillButton.danger(
          label: '确认移出',
          icon: Icons.delete_outline_rounded,
          onPressed: () => Navigator.of(context).pop(
            DeleteWorkConfirmResult(ignoreFolderOnRescan: _ignoreFolder),
          ),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '确定要将「${widget.work.title}」移出 Konata 媒体库吗？',
            style: TextStyle(
              fontSize: 14.5,
              fontWeight: FontWeight.w600,
              color: p.textPrimary,
            ),
          ),
          const SizedBox(height: 12),
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
                Icon(Icons.shield_outlined, size: 18, color: p.accent),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '媒体源严格只读：本操作仅写入软删除墓碑并清理本机 photos/ 缓存图片，绝不会删除硬盘、WebDAV 或 SMB 中的原始动画文件。',
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
          const SizedBox(height: 12),
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => setState(() => _ignoreFolder = !_ignoreFolder),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Checkbox(
                    value: _ignoreFolder,
                    onChanged: (v) =>
                        setState(() => _ignoreFolder = v ?? false),
                  ),
                  Expanded(
                    child: Text(
                      '后续扫库时自动忽略其所在源目录（避免再次自动入库）',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: p.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}
