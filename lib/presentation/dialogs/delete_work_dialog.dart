import 'package:flutter/material.dart';

import '../theme/konata_palette.dart';
import '../widgets/design_system/konata_glass_dialog.dart';
import '../widgets/design_system/konata_pill_button.dart';
import '../theme/konata_theme.dart';

/// 删除作品结果选项。
class DeleteWorkConfirmResult {
  /// 创建删除确认结果。
  const DeleteWorkConfirmResult({
    required this.confirmed,
    required this.addToIgnoreList,
  });

  /// 用户是否确认从媒体库删除。
  final bool confirmed;

  /// 是否同时把作品所在目录加入忽略名单（避免下次重扫自动复活）。
  final bool addToIgnoreList;
}

/// 高透毛玻璃作品移出媒体库确认弹窗（绝不触碰任何物理源文件）。
class DeleteWorkDialog extends StatefulWidget {
  /// 创建删除确认弹窗。
  const DeleteWorkDialog({super.key, required this.workTitle});

  /// 作品标题。
  final String workTitle;

  @override
  State<DeleteWorkDialog> createState() => _DeleteWorkDialogState();
}

class _DeleteWorkDialogState extends State<DeleteWorkDialog> {
  bool _addToIgnore = true;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return KonataGlassDialog(
      width: 440,
      title: '从媒体库中删除作品',
      onClose: () => Navigator.of(context).pop(
        const DeleteWorkConfirmResult(confirmed: false, addToIgnoreList: false),
      ),
      actions: [
        KonataPillButton.ghost(
          label: '取消',
          compact: true,
          onPressed: () => Navigator.of(context).pop(
            const DeleteWorkConfirmResult(
              confirmed: false,
              addToIgnoreList: false,
            ),
          ),
        ),
        KonataPillButton.primary(
          label: '确认移除',
          compact: true,
          onPressed: () => Navigator.of(context).pop(
            DeleteWorkConfirmResult(
              confirmed: true,
              addToIgnoreList: _addToIgnore,
            ),
          ),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '确定要将「${widget.workTitle}」从媒体库索引中删除吗？',
            style: TextStyle(
              color: p.textPrimary,
              fontSize: KonataTheme.fontSizeBodyMd,
              fontWeight: FontWeight.w500,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '此操作仅清除 Konata 数据库记录，绝对不会删除硬盘上的任何原始视频或字幕文件。',
            style: TextStyle(color: p.textSecondary, fontSize: KonataTheme.fontSizeBodyXs, height: 1.45),
          ),
          const SizedBox(height: 14),
          InkWell(
            borderRadius: KonataTheme.borderRadiusControl,
            onTap: () => setState(() => _addToIgnore = !_addToIgnore),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  SizedBox(
                    width: 22,
                    height: 22,
                    child: Checkbox(
                      value: _addToIgnore,
                      onChanged: (v) =>
                          setState(() => _addToIgnore = v ?? false),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '同时将该作品目录加入忽略名单（防止重扫自动复活）',
                      style: TextStyle(color: p.textPrimary, fontSize: KonataTheme.fontSizeBodyXs),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
