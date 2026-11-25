import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';

/// 移出媒体库确认弹窗的返回结果。
class DeleteWorkConfirmResult {
  /// 构造移除确认结果。
  const DeleteWorkConfirmResult({this.ignoreFolderOnRescan = false});

  /// 是否同步将作品所在目录加入忽略扫描列表。
  final bool ignoreFolderOnRescan;
}

/// 弹出确认框询问是否将作品移出媒体库（绝不删除本地或远程磁盘文件）。
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
      width: 480,
      title: '移出媒体库（不删除源文件）',
      onClose: () => Navigator.of(context).pop(),
      actions: <Widget>[
        KonataPillButton.ghost(
          label: '取消',
          onPressed: () => Navigator.of(context).pop(),
        ),
        KonataPillButton.danger(
          label: '移出媒体库',
          onPressed: () => Navigator.of(
            context,
          ).pop(DeleteWorkConfirmResult(ignoreFolderOnRescan: _ignoreFolder)),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            '确定要将「${widget.work.title}」从媒体库移出吗？该操作仅清理数据库元数据与播放记录，绝不会删除硬盘或远程媒体源中的视频、音频及字幕文件。',
            style: KonataTheme.bodyLabelStyle(p).copyWith(height: 1.5),
          ),
          const SizedBox(height: 16),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _ignoreFolder = !_ignoreFolder),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: p.softFill,
                borderRadius: KonataTheme.borderRadiusCard,
                border: Border.all(
                  color: _ignoreFolder
                      ? p.accentBadge.border
                      : KonataTheme.subtleControlBorder(p),
                ),
              ),
              child: Row(
                children: <Widget>[
                  SizedBox(
                    width: 22,
                    height: 22,
                    child: Checkbox(
                      value: _ignoreFolder,
                      activeColor: p.accent,
                      onChanged: (v) =>
                          setState(() => _ignoreFolder = v ?? false),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '同时忽略所在目录，后续扫描媒体源时不再重新导入',
                      style: KonataTheme.bodyLabelStyle(
                        p,
                        fontSize: KonataTheme.fontSizeBodySm,
                      ),
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
