import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';

import '../shell/konata_bottom_clearance_scope.dart';
import '../tokens/konata_adaptive_tokens.dart';
import '../tokens/konata_palette.dart';
import '../tokens/konata_theme.dart';
import 'konata_ambient_backdrop.dart';
import 'konata_draggable_scrollbar.dart';
import 'konata_page_header.dart';
import 'konata_surface_card.dart';

/// 设置分类唯一元数据，桌面与触屏共享同一个面板构造器。
class AdaptiveSettingsCategory<T> {
  /// 创建设置分类条目。
  const AdaptiveSettingsCategory({
    required this.value,
    required this.icon,
    required this.title,
    required this.summary,
    required this.panel,
    this.desktopOnly = false,
  });

  /// 分类唯一值标识。
  final T value;

  /// 分类图标。
  final IconData icon;

  /// 分类展示标题。
  final String title;

  /// 手机一级分类页展示的简短状态摘要。
  final String summary;

  /// 分类面板内容构建器。
  final WidgetBuilder panel;

  /// 是否仅在桌面端显示（Android 手机与平板自动过滤）。
  final bool desktopOnly;
}

/// 宽视口（Windows / 平板）左右分栏与手机真实推栈二级路由的共用设置框架（0 Riverpod 依赖）。
class AdaptiveSettingsContainer<T> extends StatefulWidget {
  /// 创建自适应设置容器。
  const AdaptiveSettingsContainer({
    super.key,
    required this.categories,
    required this.selected,
    required this.onSelected,
    required this.onDetailVisibilityChanged,
    this.bottomClearance = 0,
    this.deepLinkPulse = 0,
  });

  /// 设置分类列表。
  final List<AdaptiveSettingsCategory<T>> categories;

  /// 当前选中的设置分类值。
  final T selected;

  /// 选中分类变更回调。
  final ValueChanged<T> onSelected;

  /// 手机二级设置页显隐状态回调（用于隐藏/恢复底部导航胶囊）。
  final ValueChanged<bool> onDetailVisibilityChanged;

  /// 页面底部防遮挡避让高度。
  final double bottomClearance;

  /// 外部深链直达某设置分类时的递增脉冲。
  final int deepLinkPulse;

  @override
  State<AdaptiveSettingsContainer<T>> createState() =>
      _AdaptiveSettingsContainerState<T>();
}

class _AdaptiveSettingsContainerState<T>
    extends State<AdaptiveSettingsContainer<T>> {
  bool _detailOpen = false;

  @override
  void didUpdateWidget(covariant AdaptiveSettingsContainer<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    final selectedChanged = oldWidget.selected != widget.selected;
    final deepLinked = oldWidget.deepLinkPulse != widget.deepLinkPulse;
    if ((selectedChanged || deepLinked) && !_detailOpen && _phone) {
      final matches = _categories.where((c) => c.value == widget.selected);
      if (matches.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_detailOpen) _open(matches.first);
        });
      }
    }
  }

  bool get _android => KonataAdaptiveTokens.isAndroid;

  bool get _phone =>
      _android &&
      MediaQuery.sizeOf(context).shortestSide <
          KonataAdaptiveTokens.tabletBreakpoint;

  List<AdaptiveSettingsCategory<T>> get _categories =>
      widget.categories.where((c) => !_android || !c.desktopOnly).toList();

  Future<void> _open(AdaptiveSettingsCategory<T> category) async {
    if (_detailOpen) return;
    final phone = _phone;
    _detailOpen = phone;
    widget.onSelected(category.value);
    if (!phone) return;
    widget.onDetailVisibilityChanged(true);
    try {
      await Navigator.of(context).push<void>(
        CupertinoPageRoute<void>(
          builder: (context) => _SettingsDetailRoute<T>(
            categories: _categories,
            initial: category.value,
            onSelected: widget.onSelected,
            fallbackBottomClearance: widget.bottomClearance,
          ),
        ),
      );
    } finally {
      _detailOpen = false;
      widget.onDetailVisibilityChanged(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final categories = _categories;
    if (categories.isEmpty) {
      return const Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[KonataPageHeader(title: '设置')],
      );
    }
    final selected = categories.firstWhere(
      (c) => c.value == widget.selected,
      orElse: () => categories.first,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const KonataPageHeader(title: '设置'),
        Expanded(
          child: _phone
              ? _SettingsCategories<T>(
                  categories: categories,
                  selected: selected.value,
                  onTap: _open,
                  bottomClearance: widget.bottomClearance,
                  summaries: true,
                )
              : _SettingsColumns<T>(
                  categories: categories,
                  selected: selected,
                  onTap: _open,
                  bottomClearance: widget.bottomClearance,
                ),
        ),
      ],
    );
  }
}

class _SettingsDetailRoute<T> extends StatefulWidget {
  const _SettingsDetailRoute({
    required this.categories,
    required this.initial,
    required this.onSelected,
    required this.fallbackBottomClearance,
  });

  final List<AdaptiveSettingsCategory<T>> categories;
  final T initial;
  final ValueChanged<T> onSelected;
  final double fallbackBottomClearance;

  @override
  State<_SettingsDetailRoute<T>> createState() =>
      _SettingsDetailRouteState<T>();
}

class _SettingsDetailRouteState<T> extends State<_SettingsDetailRoute<T>> {
  late T _selected = widget.initial;

  @override
  Widget build(BuildContext context) {
    final clearance =
        KonataBottomClearanceScope.maybeOf(context) ??
        widget.fallbackBottomClearance;
    final category = widget.categories.firstWhere(
      (c) => c.value == _selected,
      orElse: () => widget.categories.first,
    );
    final phone =
        MediaQuery.sizeOf(context).shortestSide <
        KonataAdaptiveTokens.tabletBreakpoint;
    return Scaffold(
      backgroundColor: context.palette.isDark
          ? KonataTheme.cinemaObsidian
          : KonataTheme.themePreviewLightCanvas,
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          if (KonataAdaptiveTokens.isAndroid)
            const Positioned.fill(child: KonataAmbientShellBackdrop()),
          SafeArea(
            child: Column(
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.all(KonataAdaptiveTokens.safeGap),
                  child: Row(
                    children: <Widget>[
                      SizedBox.square(
                        dimension: KonataAdaptiveTokens.touchTarget,
                        child: IconButton(
                          key: const ValueKey('settings_detail_back'),
                          tooltip: '返回',
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.arrow_back_rounded),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          category.title,
                          style: KonataTheme.h2Style(context.palette),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: phone
                      ? _SettingsPanel<T>(
                          category: category,
                          bottomClearance: clearance,
                        )
                      : _SettingsColumns<T>(
                          categories: widget.categories,
                          selected: category,
                          onTap: (c) {
                            setState(() => _selected = c.value);
                            widget.onSelected(c.value);
                          },
                          bottomClearance: clearance,
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsColumns<T> extends StatelessWidget {
  const _SettingsColumns({
    required this.categories,
    required this.selected,
    required this.onTap,
    required this.bottomClearance,
  });

  final List<AdaptiveSettingsCategory<T>> categories;
  final AdaptiveSettingsCategory<T> selected;
  final ValueChanged<AdaptiveSettingsCategory<T>> onTap;
  final double bottomClearance;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      SizedBox(
        width: KonataAdaptiveTokens.settingsRailWidth,
        child: _SettingsCategories<T>(
          categories: categories,
          selected: selected.value,
          onTap: onTap,
          bottomClearance: bottomClearance,
        ),
      ),
      Expanded(
        child: _SettingsPanel<T>(
          category: selected,
          bottomClearance: bottomClearance,
        ),
      ),
    ],
  );
}

class _SettingsCategories<T> extends StatefulWidget {
  const _SettingsCategories({
    required this.categories,
    required this.selected,
    required this.onTap,
    required this.bottomClearance,
    this.summaries = false,
  });

  final List<AdaptiveSettingsCategory<T>> categories;
  final T selected;
  final ValueChanged<AdaptiveSettingsCategory<T>> onTap;
  final double bottomClearance;
  final bool summaries;

  @override
  State<_SettingsCategories<T>> createState() => _SettingsCategoriesState<T>();
}

class _SettingsCategoriesState<T> extends State<_SettingsCategories<T>> {
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => KonataDraggableScrollbar(
    controller: _scroll,
    balancedHorizontalInset: KonataAdaptiveTokens.horizontalInset,
    builder: (_, controller) => SingleChildScrollView(
      controller: controller,
      padding: EdgeInsets.only(bottom: widget.bottomClearance),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final c in widget.categories)
            DecoratedBox(
              decoration: BoxDecoration(
                color: !widget.summaries && c.value == widget.selected
                    ? null
                    : Colors.transparent,
                gradient: !widget.summaries && c.value == widget.selected
                    ? KonataTheme.opticalSheenGradient(
                        context.palette,
                        baseColor: context.palette.softFill,
                      )
                    : null,
                borderRadius: BorderRadius.circular(
                  KonataAdaptiveTokens.settingsRadius,
                ),
                border: !widget.summaries && c.value == widget.selected
                    ? Border.all(color: context.palette.hairline, width: 0.9)
                    : null,
              ),
              child: KonataListTile(
                key: ValueKey('settings_category_${c.value}'),
                title: c.title,
                subtitle: widget.summaries ? c.summary : null,
                leading: Icon(c.icon, color: context.palette.textSecondary),
                trailing: widget.summaries
                    ? Icon(
                        Icons.chevron_right_rounded,
                        color: context.palette.textSecondary,
                      )
                    : null,
                onTap: () => widget.onTap(c),
              ),
            ),
        ],
      ),
    ),
  );
}

class _SettingsPanel<T> extends StatefulWidget {
  const _SettingsPanel({required this.category, required this.bottomClearance});

  final AdaptiveSettingsCategory<T> category;
  final double bottomClearance;

  @override
  State<_SettingsPanel<T>> createState() => _SettingsPanelState<T>();
}

class _SettingsPanelState<T> extends State<_SettingsPanel<T>> {
  final ScrollController _scroll = ScrollController();

  @override
  void didUpdateWidget(covariant _SettingsPanel<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.category.value != widget.category.value &&
        _scroll.hasClients) {
      _scroll.jumpTo(0);
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => KonataDraggableScrollbar(
    controller: _scroll,
    balancedHorizontalInset: KonataAdaptiveTokens.horizontalInset,
    builder: (_, controller) => SingleChildScrollView(
      controller: controller,
      padding: EdgeInsets.only(
        bottom: KonataAdaptiveTokens.settingsGap + widget.bottomClearance,
      ),
      child: KeyedSubtree(
        key: ValueKey<T>(widget.category.value),
        child: widget.category.panel(context),
      ),
    ),
  );
}
