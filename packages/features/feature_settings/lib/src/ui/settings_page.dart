import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../manifest.dart';
import '../providers.dart';

/// 纯声明式三端自适应设置容器页面（不硬编码任何其他业务模块面板）。
///
/// 根据 [FeatureSettingsDependencies] 注入的聚合 [SettingsSectionContribution]
/// 列表与当前运行平台自动过滤与排序：
/// - 桌面端（Windows）与平板使用 `AdaptiveSettingsContainer` 左右分栏；
/// - 手机端使用一级分类列表 -> 二级详情页推入与返回路由。
class SettingsPage extends ConsumerStatefulWidget {
  /// 创建纯声明式设置页容器。
  const SettingsPage({
    super.key,
    this.dependencies,
    this.initialSectionId,
    this.deepLinkPulse = 0,
    this.onDetailVisibilityChanged,
  });

  /// 可选直传模块依赖集合；为空时从 [featureSettingsDependenciesProvider] 读取。
  final FeatureSettingsDependencies? dependencies;

  /// 可选默认或深链直达的设置分区标识。
  final String? initialSectionId;

  /// 外部深链触发直达目标分区时的递增脉冲值。
  final int deepLinkPulse;

  /// 手机二级设置页显隐变化回调（用于通知宿主壳层隐藏或恢复主导航胶囊）。
  final ValueChanged<bool>? onDetailVisibilityChanged;

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  String? _selectedId;

  @override
  void initState() {
    super.initState();
    _selectedId = widget.initialSectionId;
  }

  @override
  void didUpdateWidget(covariant SettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialSectionId != null &&
        (widget.initialSectionId != oldWidget.initialSectionId ||
            widget.deepLinkPulse != oldWidget.deepLinkPulse)) {
      _selectedId = widget.initialSectionId;
    }
  }

  List<SettingsSectionContribution> _resolveVisibleSections(
    FeatureSettingsDependencies deps,
  ) {
    final mergedById = <String, SettingsSectionContribution>{
      for (final builtIn in featureSettingsManifest.settingsSections)
        builtIn.id: builtIn,
    };
    for (final external in deps.sections) {
      mergedById[external.id] = external;
    }

    final visible =
        mergedById.values
            .where((section) => section.isSupportedOn(deps.currentPlatform))
            .toList()
          ..sort((a, b) {
            final orderCmp = a.order.compareTo(b.order);
            if (orderCmp != 0) {
              return orderCmp;
            }
            return a.id.compareTo(b.id);
          });
    return visible;
  }

  String _resolveEffectiveSelected(
    List<SettingsSectionContribution> visibleSections,
  ) {
    final validIds = visibleSections.map((s) => s.id).toSet();
    final raw = _selectedId;
    if (raw != null) {
      if (validIds.contains(raw)) {
        return raw;
      }
      // 保留旧深链标识 `storage` 向统一「显示与存储 (`display`)」分区的平滑映射兼容。
      if (raw == 'storage' && validIds.contains(displaySettingsSectionId)) {
        return displaySettingsSectionId;
      }
    }
    return visibleSections.first.id;
  }

  IconData _resolveSectionIcon(SettingsSectionContribution section) {
    if (section.iconKey == 'display' || section.id == 'display') {
      return Icons.tune_rounded;
    }
    if (section.iconKey == 'network' || section.id == 'network') {
      return Icons.public_rounded;
    }
    return KonataIconRegistry.resolve(section.iconKey);
  }

  @override
  Widget build(BuildContext context) {
    final directDeps = widget.dependencies;
    final FeatureSettingsDependencies deps =
        directDeps ?? ref.watch(featureSettingsDependenciesProvider);
    final contributions = _resolveVisibleSections(deps);
    final visibleSections = contributions
        .where((section) => section.parentSectionId == null)
        .toList(growable: false);

    if (visibleSections.isEmpty) {
      return const Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[KonataPageHeader(title: '设置')],
      );
    }

    final effectiveSelected = _resolveEffectiveSelected(visibleSections);

    final categories = visibleSections
        .map(
          (section) => AdaptiveSettingsCategory<String>(
            value: section.id,
            icon: _resolveSectionIcon(section),
            title: section.title,
            summary: section.subtitle ?? section.title,
            desktopOnly:
                !section.isSupportedOn(KonataPlatform.androidPhone) &&
                !section.isSupportedOn(KonataPlatform.androidTablet),
            panel: (ctx) {
              final panels = <Widget>[
                for (final contribution in [
                  ...contributions.where(
                    (item) => item.parentSectionId == section.id,
                  ),
                  section,
                ])
                  if (contribution.viewBuilder(
                        ViewSlotContext(
                          platformContext: ctx,
                          arguments: <String, Object?>{
                            'sectionId': contribution.id,
                          },
                        ),
                      )
                      case final Widget panel)
                    panel,
              ];
              if (panels.isEmpty) return const SizedBox.shrink();
              if (panels.length == 1) return panels.single;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < panels.length; i++) ...[
                    if (i > 0) const SizedBox(height: 16),
                    panels[i],
                  ],
                ],
              );
            },
          ),
        )
        .toList(growable: false);

    return AdaptiveSettingsContainer<String>(
      categories: categories,
      selected: effectiveSelected,
      deepLinkPulse: widget.deepLinkPulse,
      bottomClearance: KonataBottomClearanceScope.of(context),
      onSelected: (nextId) {
        if (_selectedId != nextId) {
          setState(() {
            _selectedId = nextId;
          });
        }
      },
      onDetailVisibilityChanged:
          widget.onDetailVisibilityChanged ??
          deps.onDetailVisibilityChanged ??
          (_) {},
    );
  }
}
