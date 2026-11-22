import 'package:material_ui/material_ui.dart';

import '../../theme/konata_adaptive_tokens.dart';
import '../../theme/konata_palette.dart';
import '../../theme/konata_theme.dart';
import '../playback/konata_playback_capsule.dart';
import 'konata_glass_dialog.dart';
import 'konata_soft_text_field.dart';

/// 自适应顶栏高频图标或溢出动作描述符。
class AdaptiveHeaderAction {
  /// 创建自适应顶栏动作条目。
  const AdaptiveHeaderAction({
    this.buttonKey,
    required this.icon,
    required this.label,
    this.tooltip,
    required this.onPressed,
    this.highlighted = false,
    this.wideWidget,
    this.preserveWideWidgetOnNarrow = false,
  });

  /// 可选测试/语义定位键。
  final Key? buttonKey;

  /// 窄屏图标按钮与底部抽屉列表使用的图标。
  final IconData icon;

  /// 动作名称（用于溢出底部抽屉清单与无障碍语义）。
  final String label;

  /// 悬停或长按提示（缺省回退 [label]）。
  final String? tooltip;

  /// 点击触发回调（为空表示禁用）。
  final VoidCallback? onPressed;

  /// 是否处于激活高亮态（如待复核有条数或筛选激活）。
  final bool highlighted;

  /// 宽视口（桌面/平板横屏）平铺展示的自定义胶囊控件；缺省回退为图标按钮。
  final Widget? wideWidget;

  /// 窄视口（手机及平板竖屏）是否强制保留 [wideWidget] 图文胶囊形态而不折叠为纯图标。
  final bool preserveWideWidgetOnNarrow;
}

/// 基于 `LayoutBuilder` 实时测量可用宽度的自适应顶栏组件。
///
/// 宽视口（`>= 620dp`）保持左侧大标题（+ 可选徽章）与右侧平铺搜索框、操作胶囊对齐；
/// 窄视口下自动收起冗余项：仅保留标题 + 最多 2 个高频图标按钮（触控热区 `>= 48dp`），
/// 搜索框默认折叠为图标并支持原地展开，其余次要动作与过滤排序自动移入毛玻璃底部抽屉。
class AdaptiveActionHeader extends StatefulWidget {
  /// 创建自适应顶栏。
  const AdaptiveActionHeader({
    super.key,
    required this.title,
    this.badge,
    this.primaryActions = const [],
    this.overflowActions = const [],
    this.overflowSheetTitle = '更多操作',
    this.overflowContentBuilder,
    this.wideLeadingExtra = const [],
    this.searchQuery,
    this.onSearchChanged,
    this.searchHint = '搜索番剧名称、原名或年份',
    this.searchFocusNode,
    this.narrowBreakpoint = 620.0,
  });

  /// 核心主标题。
  final String title;

  /// 可选紧邻主标题右侧的统计徽章。
  final Widget? badge;

  /// 高频主操作列表（窄屏最多直接露出 2 个，超出部分自动进入底部抽屉）。
  final List<AdaptiveHeaderAction> primaryActions;

  /// 次要/低频操作（窄屏收入底部毛玻璃抽屉；宽屏如无自定义排布亦可平铺）。
  final List<AdaptiveHeaderAction> overflowActions;

  /// 窄屏点击更多操作时弹出的底部抽屉标题。
  final String overflowSheetTitle;

  /// 可选附加在底部抽屉内部的自定义排序/过滤控件构建器。
  final WidgetBuilder? overflowContentBuilder;

  /// 宽屏下紧邻操作区左侧平铺展示的控件（如筛选下拉框或排序条）。
  final List<Widget> wideLeadingExtra;

  /// 可选内嵌搜索当前查询文本（传入 [onSearchChanged] 时启用折叠/展开搜索功能）。
  final String? searchQuery;

  /// 搜索文本变更回调。
  final ValueChanged<String>? onSearchChanged;

  /// 搜索输入框占位提示。
  final String searchHint;

  /// 可选搜索聚焦节点（支持快捷键 Ctrl+K 聚焦）。
  final FocusNode? searchFocusNode;

  /// 宽窄布局切换宽度阈值。
  final double narrowBreakpoint;

  @override
  State<AdaptiveActionHeader> createState() => _AdaptiveActionHeaderState();
}

class _AdaptiveActionHeaderState extends State<AdaptiveActionHeader> {
  final TextEditingController _searchCtrl = TextEditingController();
  late final FocusNode _internalFocusNode = FocusNode();
  bool _narrowSearchExpanded = false;

  FocusNode get _effectiveFocusNode =>
      widget.searchFocusNode ?? _internalFocusNode;

  @override
  void initState() {
    super.initState();
    _syncControllerText(widget.searchQuery ?? '');
    _searchCtrl.addListener(_handleSearchCtrlChanged);
  }

  void _handleSearchCtrlChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void didUpdateWidget(covariant AdaptiveActionHeader oldWidget) {
    super.didUpdateWidget(oldWidget);
    final incoming = widget.searchQuery ?? '';
    if (incoming != _searchCtrl.text) {
      _syncControllerText(incoming);
    }
    if (incoming.isNotEmpty && !_narrowSearchExpanded) {
      _narrowSearchExpanded = true;
    }
  }

  void _syncControllerText(String value) {
    _searchCtrl.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  @override
  void dispose() {
    _searchCtrl.removeListener(_handleSearchCtrlChanged);
    _searchCtrl.dispose();
    _internalFocusNode.dispose();
    super.dispose();
  }

  void _openNarrowSearch() {
    setState(() => _narrowSearchExpanded = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _effectiveFocusNode.requestFocus();
      }
    });
  }

  void _closeNarrowSearch() {
    _searchCtrl.clear();
    widget.onSearchChanged?.call('');
    _effectiveFocusNode.unfocus();
    setState(() => _narrowSearchExpanded = false);
  }

  void _openOverflowSheet(List<AdaptiveHeaderAction> drawerActions) {
    showKonataGlassBottomSheet<void>(
      context: context,
      title: widget.overflowSheetTitle,
      builder: (sheetCtx) {
        final p = sheetCtx.palette;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.overflowContentBuilder != null) ...[
              widget.overflowContentBuilder!(sheetCtx),
              if (drawerActions.isNotEmpty) ...[
                const SizedBox(height: 12),
                Divider(height: 1, thickness: 1, color: p.hairline),
                const SizedBox(height: 8),
              ],
            ],
            for (final action in drawerActions)
              InkWell(
                borderRadius: KonataTheme.borderRadiusCard,
                onTap: action.onPressed == null
                    ? null
                    : () {
                        Navigator.of(sheetCtx).pop();
                        action.onPressed!();
                      },
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: KonataAdaptiveTokens.touchTarget,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          action.icon,
                          size: 20,
                          color: action.highlighted
                              ? p.progressFill
                              : p.textSecondary,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            action.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: action.onPressed == null
                                  ? p.textMuted
                                  : p.textPrimary,
                              fontSize: KonataTheme.fontSizeSubtitle,
                              fontWeight: action.highlighted
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildIconButton(AdaptiveHeaderAction action, {double size = 20}) {
    final p = context.palette;
    final btnSize = KonataAdaptiveTokens.isAndroid
        ? KonataAdaptiveTokens.touchTarget
        : 38.0;
    return KonataCapsuleIconButton(
      key: action.buttonKey,
      icon: action.icon,
      tooltip: action.tooltip ?? action.label,
      color: action.highlighted ? p.progressFill : p.textPrimary,
      highlighted: action.highlighted,
      highlightColor: p.progressFill,
      size: size,
      fixedSize: btnSize,
      onTap: action.onPressed,
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final hasSearch = widget.onSearchChanged != null;

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= widget.narrowBreakpoint;
        final horizontalPad = wide
            ? KonataTheme.pageHorizontalPadding
            : KonataAdaptiveTokens.horizontalInset;

        if (wide) {
          final allActions = [
            ...widget.primaryActions,
            ...widget.overflowActions,
          ];
          return Padding(
            padding: EdgeInsets.fromLTRB(
              horizontalPad,
              KonataTheme.pageHeaderTopSpacing,
              horizontalPad,
              KonataTheme.pageHeaderBottomSpacing,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: constraints.maxWidth * 0.48,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          widget.title,
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.ellipsis,
                          style: KonataTheme.h1Style(p),
                        ),
                      ),
                      if (widget.badge != null) ...[
                        const SizedBox(width: 12),
                        widget.badge!,
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      alignment: WrapAlignment.end,
                      children: [
                        ...widget.wideLeadingExtra,
                        if (hasSearch)
                          SizedBox(
                            width: 220,
                            child: KonataSoftTextField(
                              controller: _searchCtrl,
                              focusNode: _effectiveFocusNode,
                              hintText: widget.searchHint,
                              height: 36,
                              prefixIcon: Icons.search_rounded,
                              suffix: _searchCtrl.text.isNotEmpty
                                  ? IconButton(
                                      tooltip: '清除搜索',
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                      icon: Icon(
                                        Icons.close_rounded,
                                        size: 16,
                                        color: p.textSecondary,
                                      ),
                                      onPressed: () {
                                        _searchCtrl.clear();
                                        widget.onSearchChanged?.call('');
                                      },
                                    )
                                  : null,
                              onChanged: widget.onSearchChanged,
                            ),
                          ),
                        for (final action in allActions)
                          action.wideWidget ?? _buildIconButton(action),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        }

        // 窄屏原地展开搜索框模式
        if (hasSearch && _narrowSearchExpanded) {
          return Padding(
            padding: EdgeInsets.fromLTRB(
              horizontalPad,
              KonataAdaptiveTokens.safeGap,
              horizontalPad,
              KonataAdaptiveTokens.safeGap,
            ),
            child: Row(
              children: [
                KonataCapsuleIconButton(
                  key: const ValueKey('adaptive_header_search_back'),
                  icon: Icons.arrow_back_rounded,
                  tooltip: '收起搜索',
                  color: p.textPrimary,
                  size: 20,
                  fixedSize: KonataAdaptiveTokens.touchTarget,
                  onTap: _closeNarrowSearch,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: KonataSoftTextField(
                    controller: _searchCtrl,
                    focusNode: _effectiveFocusNode,
                    hintText: widget.searchHint,
                    height: 40,
                    prefixIcon: Icons.search_rounded,
                    suffix: _searchCtrl.text.isNotEmpty
                        ? IconButton(
                            tooltip: '清除搜索',
                            onPressed: () {
                              _searchCtrl.clear();
                              widget.onSearchChanged?.call('');
                            },
                            icon: Icon(
                              Icons.close_rounded,
                              size: 18,
                              color: p.textSecondary,
                            ),
                          )
                        : null,
                    onChanged: widget.onSearchChanged,
                  ),
                ),
              ],
            ),
          );
        }

        // 窄屏默认态：最多直接保留 2 个高频按钮（含折叠搜索），其余一律自动收纳进底部抽屉
        final maxDirectCount = hasSearch ? 1 : 2;
        final visiblePrimary = widget.primaryActions
            .take(maxDirectCount)
            .toList(growable: false);
        final hiddenPrimary = widget.primaryActions
            .skip(maxDirectCount)
            .toList(growable: false);
        final drawerActions = [...hiddenPrimary, ...widget.overflowActions];
        final showOverflowButton =
            drawerActions.isNotEmpty || widget.overflowContentBuilder != null;

        final showBadgeInline =
            widget.badge != null && constraints.maxWidth >= 380;
        final showBadgeBelow =
            widget.badge != null && constraints.maxWidth < 380;

        return Padding(
          padding: EdgeInsets.fromLTRB(
            horizontalPad,
            KonataAdaptiveTokens.safeGap,
            horizontalPad,
            KonataAdaptiveTokens.safeGap,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            widget.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: KonataTheme.h1Style(p),
                          ),
                        ),
                        if (showBadgeInline) ...[
                          const SizedBox(width: 8),
                          MediaQuery.withClampedTextScaling(
                            maxScaleFactor: 1.15,
                            child: widget.badge!,
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (hasSearch)
                    _buildIconButton(
                      AdaptiveHeaderAction(
                        buttonKey: const ValueKey('adaptive_header_search_icon'),
                        icon: Icons.search_rounded,
                        label: '搜索',
                        onPressed: _openNarrowSearch,
                      ),
                    ),
                  for (final action in visiblePrimary)
                    (action.preserveWideWidgetOnNarrow &&
                            action.wideWidget != null)
                        ? action.wideWidget!
                        : _buildIconButton(action),
                  if (showOverflowButton)
                    _buildIconButton(
                      AdaptiveHeaderAction(
                        buttonKey: const ValueKey('adaptive_header_more_icon'),
                        icon: Icons.tune_rounded,
                        label: widget.overflowSheetTitle,
                        onPressed: () => _openOverflowSheet(drawerActions),
                      ),
                    ),
                ],
              ),
              if (showBadgeBelow) ...[
                const SizedBox(height: 6),
                MediaQuery.withClampedTextScaling(
                  maxScaleFactor: 1.15,
                  child: widget.badge!,
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
