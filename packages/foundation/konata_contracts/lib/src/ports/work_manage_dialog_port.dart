import '../value_objects/ids.dart';

/// 作品管理共享弹窗跨包动作端口。
///
/// 由应用宿主在启动装配期绑定至 `feature_detail` 唯一完整版弹窗实现，
/// 使 `feature_library` 仅通过强类型 `WorkId` 唤起统一弹窗，
/// 彻底消除海报墙与详情页双套重复 UI 且严守禁止 Feature 横向互引红线。
abstract interface class WorkManageDialogPort {
  /// 弹出作品手动精确匹配或拆簇建新弹窗，完成绑定或拆簇返回 `true`。
  Future<bool> showManualMatchDialog(
    Object platformContext, {
    required WorkId workId,
    List<VariantId>? splitVariantIds,
  });

  /// 弹出作品源文件清单复核弹窗（内含拆分与合并入口），发生变更返回 `true`。
  Future<bool> showSourceFilesReviewDialog(
    Object platformContext, {
    required WorkId workId,
  });

  /// 弹出将整部作品或指定物理文件并入已有作品的目标选择弹窗，完成合并返回 `true`。
  Future<bool> showWorkMergeDialog(
    Object platformContext, {
    required WorkId sourceWorkId,
    List<VariantId> variantIds = const <VariantId>[],
    String? dialogTitle,
  });
}
