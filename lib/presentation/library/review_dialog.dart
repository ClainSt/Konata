import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/library_providers.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/konata_draggable_scrollbar.dart';
import '../widgets/design_system/konata_glass_dialog.dart';
import 'review_work_item_card.dart';

/// 以屏幕正中宽幅可拖拽毛玻璃弹窗形式打开「待复核」手动纠错队列。
Future<void> showReviewDialog(BuildContext context) {
  return showKonataGlassDialog<void>(
    context: context,
    builder: (_) => const ReviewDialog(),
  );
}

/// 居中宽幅 0 延迟可拖拽「待复核」手动纠错毛玻璃弹窗。
class ReviewDialog extends ConsumerWidget {
  /// 创建待复核弹窗。
  const ReviewDialog({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(needsReviewItemsProvider, (previous, next) {
      final prevCount = previous?.valueOrNull?.length ?? 0;
      final nextItems = next.valueOrNull;
      if (prevCount > 0 && nextItems != null && nextItems.isEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (context.mounted) {
            Navigator.of(context).maybePop();
          }
        });
      }
    });

    final p = context.palette;
    final reviewAsync = ref.watch(needsReviewItemsProvider);
    final viewport = MediaQuery.sizeOf(context);
    final maxSafeWidth = math.max(
      220.0,
      viewport.width - KonataTheme.dialogViewportMargin * 2,
    );
    final dialogWidth = math.min(
      maxSafeWidth,
      (viewport.width * 0.74).clamp(760.0, 960.0),
    );
    final dialogMaxHeight = viewport.height * 0.84;

    final pendingCount = reviewAsync.valueOrNull?.length ?? 0;

    return KonataGlassDialog(
      title: '待复核',
      width: dialogWidth,
      maxHeight: dialogMaxHeight,
      headerTrailing: pendingCount > 0
          ? Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
              decoration: BoxDecoration(
                color: p.warningBadge.bg,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: p.warningBadge.border, width: 1),
              ),
              child: Text(
                '$pendingCount 项',
                style: TextStyle(
                  color: p.warningBadge.fg,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            )
          : null,
      child: reviewAsync.when(
        data: (items) {
          if (items.isEmpty) {
            return SizedBox(
              height: 220,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.fact_check_outlined,
                      size: 38,
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
          return ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: math.max(180.0, dialogMaxHeight - 104.0),
            ),
            child: KonataDraggableScrollbar(
              builder: (_, ctrl) => ListView.separated(
                controller: ctrl,
                shrinkWrap: true,
                padding: const EdgeInsets.only(right: 16, top: 2, bottom: 4),
                itemCount: items.length,
                separatorBuilder: (_, _) => const SizedBox(height: 12),
                itemBuilder: (_, index) =>
                    ReviewWorkItemCard(item: items[index]),
              ),
            ),
          );
        },
        loading: () => const SizedBox(
          height: 220,
          child: Center(child: CircularProgressIndicator()),
        ),
        error: (err, _) => SizedBox(
          height: 220,
          child: Center(
            child: Text('加载待复核列表失败: $err', style: TextStyle(color: p.danger)),
          ),
        ),
      ),
    );
  }
}
