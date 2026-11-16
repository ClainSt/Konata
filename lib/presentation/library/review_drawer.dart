import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/library_providers.dart';
import '../theme/konata_palette.dart';
import '../widgets/design_system/konata_draggable_scrollbar.dart';
import '../widgets/design_system/konata_glass_side_sheet.dart';
import 'review_work_item_card.dart';

/// 右侧悬浮内嵌毛玻璃「待复核」手动纠错侧栏。
class ReviewDrawer extends ConsumerWidget {
  /// 创建待复核侧栏。
  const ReviewDrawer({super.key, required this.onClose});

  /// 关闭侧栏回调。
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final reviewAsync = ref.watch(needsReviewItemsProvider);

    return KonataGlassSideSheet(
      title: '待复核',
      width: 456,
      onClose: onClose,
      child: reviewAsync.when(
        data: (items) {
          if (items.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 36),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.fact_check_outlined,
                      size: 36,
                      color: p.textSecondary,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '当前没有待复核的作品',
                      style: TextStyle(
                        color: p.textSecondary,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }
          return KonataDraggableScrollbar(
            builder: (_, ctrl) => ListView.separated(
              controller: ctrl,
              padding: const EdgeInsets.fromLTRB(18, 4, 20, 18),
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (_, index) => ReviewWorkItemCard(item: items[index]),
            ),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => Center(
          child: Text(
            '加载待复核列表失败: $err',
            style: TextStyle(color: p.danger),
          ),
        ),
      ),
    );
  }
}
