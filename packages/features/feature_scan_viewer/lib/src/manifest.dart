import 'package:flutter/widgets.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

import 'data/scan_gallery_repository.dart';
import 'ui/scan_gallery_tab_host.dart';
import 'ui/scan_gallery_view.dart';

/// 扫图画廊详情页标签可用性与槽位构建静态入口（供宿主外壳或详情页按需判定与渲染）。
abstract final class ScanViewerAvailability {
  /// 扫图详情页扩展标签稳定标识。
  static const String detailTabId = 'scan_viewer';

  /// 判断指定作品（含同系列 `seriesShared` 资源）是否存在可展示的扫图资产。
  static bool hasScansForWork(KonataDatabaseBundle databases, WorkId workId) {
    return ScanGalleryRepository.hasScansForWork(databases, workId);
  }

  /// 统计指定作品（含同系列 `seriesShared` 资源）可见的扫图总张数。
  static int countScansForWork(KonataDatabaseBundle databases, WorkId workId) {
    return ScanGalleryRepository.countScansForWork(databases, workId);
  }

  /// 通过 [ViewSlotContext] 解析作品标识并渲染 [ScanGalleryTabHost]。
  static Widget buildTabView(ViewSlotContext context) {
    final workId = _resolveWorkId(context);
    if (workId == null) {
      return const Center(child: Text('未提供有效作品标识，无法加载扫图画廊'));
    }
    final rawVolumeKey = context.arguments['volumeKey'];
    final volumeKey = rawVolumeKey is String && rawVolumeKey.trim().isNotEmpty
        ? rawVolumeKey
        : null;
    final rawController = context.arguments['scrollController'];
    final scrollController = rawController is ScrollController
        ? rawController
        : null;
    final rawOnScanTap = context.arguments['onScanTap'];
    final onScanTap = rawOnScanTap is ScanTapCallback ? rawOnScanTap : null;

    return ScanGalleryTabHost(
      workId: workId,
      inlineRail: context.arguments['inlineRail'] == true,
      searchQuery: context.arguments['searchQuery'] is String
          ? context.arguments['searchQuery'] as String
          : '',
      initialVolumeKey: volumeKey,
      scrollController: scrollController,
      onScanTap: onScanTap,
    );
  }

  static WorkId? _resolveWorkId(ViewSlotContext context) {
    if (context.workId != null) return context.workId;
    final raw = context.arguments['workId'];
    if (raw is WorkId) return raw;
    if (raw is String && raw.trim().isNotEmpty) {
      return WorkId(raw.trim());
    }
    return null;
  }
}

Object _buildScanViewerTabSlot(ViewSlotContext context) =>
    ScanViewerAvailability.buildTabView(context);

/// `feature_scan_viewer` 静态声明式扩展清单常量（可直接注册于全局扩展点清单）。
const FeatureManifest featureScanViewerManifest = FeatureManifest(
  id: 'feature_scan_viewer',
  displayName: '扫图画廊',
  detailTabs: <DetailTabContribution>[
    DetailTabContribution(
      id: ScanViewerAvailability.detailTabId,
      label: '扫图',
      iconKey: 'scan_viewer',
      order: 40,
      viewBuilder: _buildScanViewerTabSlot,
    ),
  ],
);

/// 构造绑定动态作品扫图可见性判定的扩展清单（当作品无扫图时详情页自动隐藏「扫图」标签）。
FeatureManifest createFeatureScanViewerManifest({
  required KonataDatabaseBundle databases,
}) {
  return FeatureManifest(
    id: 'feature_scan_viewer',
    displayName: '扫图画廊',
    detailTabs: <DetailTabContribution>[
      DetailTabContribution(
        id: ScanViewerAvailability.detailTabId,
        label: '扫图',
        iconKey: 'scan_viewer',
        order: 40,
        viewBuilder: _buildScanViewerTabSlot,
        isVisibleForWork: (workId) =>
            ScanViewerAvailability.hasScansForWork(databases, workId),
      ),
    ],
  );
}
