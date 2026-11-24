import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';

/// 目录范围选择器中的已选作用域摘要侧边面板。
///
/// 展示当前勾选的相对目录列表、全盘模式状态与快速单条/一键移除动作。
class SourceSelectedScopePanel extends StatelessWidget {
  /// 创建已选作用域摘要面板。
  const SourceSelectedScopePanel({
    super.key,
    required this.selectedPaths,
    required this.onRemovePath,
    required this.onClearAll,
  });

  /// 当前已勾选的相对目录集合（空列表表示全盘根目录扫描）。
  final List<String> selectedPaths;

  /// 取消勾选指定目录的回调。
  final ValueChanged<String> onRemovePath;

  /// 清空所有子目录勾选（切回全盘根目录）的回调。
  final VoidCallback onClearAll;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final hasCustomScope = selectedPaths.isNotEmpty;

    return Container(
      decoration: BoxDecoration(
        color: p.elevatedSurface.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: p.hairline),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                hasCustomScope
                    ? Icons.checklist_rtl_rounded
                    : Icons.folder_copy_outlined,
                size: 16,
                color: p.accent,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  hasCustomScope
                      ? '已选范围 (${selectedPaths.length})'
                      : '全盘根目录模式',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: p.textPrimary,
                  ),
                ),
              ),
              if (hasCustomScope)
                KonataPillButton.ghost(
                  label: '清空',
                  compact: true,
                  onPressed: onClearAll,
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (!hasCustomScope)
            Text(
              '未勾选具体子文件夹时，扫库将默认遍历媒体源根目录下的全部动画目录。',
              style: TextStyle(
                fontSize: 12,
                color: p.textSecondary,
                height: 1.45,
              ),
            )
          else
            Expanded(
              child: KonataDraggableScrollbar(
                builder: (context, scrollCtrl) => ListView.separated(
                  controller: scrollCtrl,
                  itemCount: selectedPaths.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 6),
                  itemBuilder: (context, index) {
                    final rel = selectedPaths[index];
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: p.surface.withValues(alpha: 0.68),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: p.hairline),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.folder_rounded,
                            size: 15,
                            color: p.accent,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              rel,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: p.textPrimary,
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          KonataCapsuleIconButton(
                            icon: Icons.close_rounded,
                            tooltip: '移出作用域',
                            color: p.textSecondary,
                            size: 14,
                            padding: const EdgeInsets.all(5),
                            onTap: () => onRemovePath(rel),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }
}
