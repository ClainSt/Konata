import 'dart:async';

import 'package:engine_scraping/engine_scraping.dart' show ManagedImageLoader;
import 'package:feature_detail/feature_detail.dart' as detail;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';

/// 通过应用宿主把媒体库的作品管理动作交给详情模块。
final class HostWorkManageDialogs implements WorkManageDialogPort {
  /// 创建共享作品管理弹窗适配器。
  const HostWorkManageDialogs();

  @override
  Future<bool> showManualMatchDialog(
    Object platformContext, {
    required WorkId workId,
    List<VariantId>? splitVariantIds,
  }) {
    final context = platformContext as BuildContext;
    return _withWork(context, workId, (controller, bundle, loader) async {
      return await showKonataGlassDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder: (_) => detail.ManualMatchDialog(
              controller: controller,
              bundle: bundle,
              imageLoader: loader,
              splitVariantIds: splitVariantIds?.map((id) => id.value).toList(),
            ),
          ) ??
          false;
    });
  }

  @override
  Future<bool> showSourceFilesReviewDialog(
    Object platformContext, {
    required WorkId workId,
  }) {
    final context = platformContext as BuildContext;
    return _withWork(
      context,
      workId,
      (controller, bundle, loader) => detail.showSourceFilesReviewDialog(
        context: context,
        controller: controller,
        bundle: bundle,
        imageLoader: loader,
      ),
    );
  }

  @override
  Future<bool> showWorkMergeDialog(
    Object platformContext, {
    required WorkId sourceWorkId,
    List<VariantId> variantIds = const <VariantId>[],
    String? dialogTitle,
  }) {
    final context = platformContext as BuildContext;
    return _withWork(context, sourceWorkId, (controller, bundle, loader) async {
      final outcome = await showKonataGlassDialog<detail.WorkMergeOutcome>(
        context: context,
        barrierDismissible: false,
        builder: (_) => detail.WorkMergeTargetDialog(
          controller: controller,
          sourceWorkId: bundle.work.id,
          sourceWorkTitle: bundle.work.title,
          imageLoader: loader,
          variantIds: variantIds.map((id) => id.value).toList(),
          dialogTitle: dialogTitle,
        ),
      );
      if (outcome != null && context.mounted) {
        showKonataToast(
          context,
          '已并入「${outcome.targetWork.title}」（迁移 ${outcome.movedVariantCount} 个文件）',
        );
      }
      return outcome != null;
    });
  }

  Future<bool> _withWork(
    BuildContext context,
    WorkId workId,
    Future<bool> Function(
      detail.WorkDetailController controller,
      detail.WorkDetailBundle bundle,
      ManagedImageLoader loader,
    )
    open,
  ) async {
    if (!context.mounted) return false;
    final container = ProviderScope.containerOf(context, listen: false);
    final subscription = container.listen(
      detail.workDetailControllerProvider(workId),
      (_, _) {},
    );
    try {
      final controller = subscription.read();
      if (controller.isLoading) {
        // 保留控制器直至首轮加载和所有后续弹窗操作结束。
        final ready = Completer<void>();
        void completeWhenReady() {
          if (!controller.isLoading && !ready.isCompleted) ready.complete();
        }

        controller.addListener(completeWhenReady);
        try {
          completeWhenReady();
          await ready.future;
        } finally {
          controller.removeListener(completeWhenReady);
        }
      }
      if (!context.mounted) return false;
      final bundle = controller.bundle;
      if (bundle == null) {
        showKonataToast(context, '无法加载作品信息', isError: true);
        return false;
      }
      return await open(
        controller,
        bundle,
        container.read(detail.detailManagedImageLoaderProvider),
      );
    } finally {
      subscription.close();
    }
  }
}
