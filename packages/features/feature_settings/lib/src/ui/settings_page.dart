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

    final visible = mergedById.values
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

  @override
  Widget build(BuildContext context) {
    final directDeps = widget.dependencies;
    final FeatureSettingsDependencies deps =
        directDeps ?? ref.watch(featureSettingsDependenciesProvider);
    final visibleSections = _resolveVisibleSections(deps);

    if (visibleSections.isEmpty) {
      return const Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[KonataPageHeader(title: '设置')],
      );
    }

    final validIds = visibleSections.map((s) => s.id).toSet();
    final effectiveSelected =
        (_selectedId != null && validIds.contains(_selectedId))
        ? _selectedId!
        : visibleSections.first.id;

    final categories = visibleSections
        .map(
          (section) => AdaptiveSettingsCategory<String>(
            value: section.id,
            icon: KonataIconRegistry.resolve(section.iconKey),
            title: section.title,
            summary: section.subtitle ?? section.title,
            desktopOnly:
                !section.isSupportedOn(KonataPlatform.androidPhone) &&
                !section.isSupportedOn(KonataPlatform.androidTablet),
            panel: (ctx) {
              final built = section.viewBuilder(
                ViewSlotContext(
                  platformContext: ctx,
                  arguments: <String, Object?>{'sectionId': section.id},
                ),
              );
              if (built is Widget) {
                return built;
              }
              return const SizedBox.shrink();
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
