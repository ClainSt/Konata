import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/konata_adaptive_tokens.dart';
import '../../theme/konata_palette.dart';
import '../../theme/konata_theme.dart';
import 'adaptive_responsive_row.dart';

/// 全站统一圆角 `12px` 半透明微光卡片容器，直接透出底层系统 DWM 光影。
///
/// 静态卡片（`enableHover == false`）直接渲染轻量 `DecoratedBox` + `Padding`，
/// 避免为全站静态设置项与信息卡片分配多余的 `AnimationController` 与 Ticker。
class KonataSurfaceCard extends StatefulWidget {
  /// 创建微光描边卡片容器。
  const KonataSurfaceCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.radius = KonataTheme.radiusCard,
    this.enableHover = false,
    this.backgroundColor,
    this.borderColor,
  });

  /// 子组件。
  final Widget child;

  /// 内边距。
  final EdgeInsetsGeometry padding;

  /// 圆角半径（默认 12px）。
  final double radius;

  /// 是否在鼠标悬停时平滑提亮半透明表面。
  final bool enableHover;

  /// 可选自定义表面背景色（用于选中高亮态等覆盖）。
  final Color? backgroundColor;

  /// 可选自定义 1px 边框色（用于选中高亮态等覆盖）。
  final Color? borderColor;

  @override
  State<KonataSurfaceCard> createState() => _KonataSurfaceCardState();
}

class _KonataSurfaceCardState extends State<KonataSurfaceCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final radius = widget.radius == KonataTheme.radiusCard
        ? KonataTheme.borderRadiusCard
        : BorderRadius.circular(widget.radius);

    if (!widget.enableHover) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: widget.backgroundColor ?? p.surface,
          borderRadius: radius,
          border: Border.all(
            color: widget.borderColor ?? p.hairline,
            width: 1,
          ),
        ),
        child: Padding(padding: widget.padding, child: widget.child),
      );
    }

    final box = AnimatedContainer(
      duration: KonataTheme.motionMicro,
      padding: widget.padding,
      decoration: BoxDecoration(
        color: widget.backgroundColor ?? (_hovered ? p.surfaceHover : p.surface),
        borderRadius: radius,
        border: Border.all(
          color: widget.borderColor ?? (_hovered ? p.hoverBorder : p.hairline),
          width: 1,
        ),
      ),
      child: widget.child,
    );

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: box,
    );
  }
}

/// 统一列表行组件，用于设置项卡片行、外部链接卡片与日志导出行。
class KonataListTile extends StatefulWidget {
  /// 创建列表行组件。
  const KonataListTile({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.estimatedTrailingWidth = 68.0,
    this.expandTrailingWhenStacked = false,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    this.onTap,
  });

  /// 主标题。
  final String title;

  /// 可选副标题。
  final String? subtitle;

  /// 可选左侧图标或徽标。
  final Widget? leading;

  /// 可选右侧控件（如 Switch 或箭头图标）。
  final Widget? trailing;

  /// 预估右侧控件宽度（用于窄屏防挤字自动换位判断）。
  final double estimatedTrailingWidth;

  /// 自动换位至纵向堆叠时右侧控件是否横向撑满。
  final bool expandTrailingWhenStacked;

  /// 列表行内边距（支持在侧栏中按需收紧）。
  final EdgeInsetsGeometry padding;

  /// 点击整行回调。
  final VoidCallback? onTap;

  @override
  State<KonataListTile> createState() => _KonataListTileState();
}

class _KonataListTileState extends State<KonataListTile> {
  bool _hovered = false;

  void _setHovered(bool hovered) {
    if (_hovered == hovered || !mounted) return;
    setState(() => _hovered = hovered);
  }

  Widget _buildContent(BuildContext context, KonataPalette p) {
    final titleBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          widget.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: p.textPrimary,
            fontSize: KonataTheme.fontSizeSubtitle,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (widget.subtitle != null && widget.subtitle!.isNotEmpty) ...[
          const SizedBox(height: 3),
          Text(
            widget.subtitle!,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: p.textSecondary,
              fontSize: KonataTheme.fontSizeBodyXs,
              height: 1.4,
            ),
          ),
        ],
      ],
    );

    if (widget.trailing == null) {
      return Row(
        children: [
          if (widget.leading != null) ...[
            widget.leading!,
            const SizedBox(width: 14),
          ],
          Expanded(child: titleBlock),
        ],
      );
    }

    final leadingRow = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (widget.leading != null) ...[
          widget.leading!,
          const SizedBox(width: 14),
        ],
        Expanded(child: titleBlock),
      ],
    );

    final scale = (MediaQuery.textScalerOf(context).scale(14.0) / 14.0).clamp(
      1.0,
      1.45,
    );
    final hasSubtitle = widget.subtitle != null && widget.subtitle!.isNotEmpty;
    var minLead = widget.leading != null ? 176.0 : 140.0;
    if (!hasSubtitle) {
      final titlePainter = TextPainter(
        text: TextSpan(
          text: widget.title,
          style: DefaultTextStyle.of(context).style.merge(
            const TextStyle(
              fontSize: KonataTheme.fontSizeSubtitle,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        maxLines: 1,
        textDirection: Directionality.maybeOf(context) ?? TextDirection.ltr,
        textScaler: MediaQuery.textScalerOf(context),
      )..layout();
      final iconSpace = widget.leading != null ? 40.0 : 4.0;
      final singleLineNeeded = (titlePainter.width + iconSpace) / scale;
      if (singleLineNeeded < minLead) {
        minLead = math.max(88.0, singleLineNeeded);
      }
    }

    return AdaptiveResponsiveRow(
      leading: leadingRow,
      trailing: widget.trailing!,
      estimatedTrailingWidth: widget.estimatedTrailingWidth,
      minLeadingWidth: minLead,
      expandTrailingWhenStacked: widget.expandTrailingWhenStacked,
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final clickable = widget.onTap != null;
    final content = Padding(
      padding: widget.padding,
      child: _buildContent(context, p),
    );

    // 不可点击行或触屏 Android 直接跳过鼠标悬停监听与动画控制器，降低列表重建与内存开销。
    if (!clickable) {
      return content;
    }
    if (KonataAdaptiveTokens.isAndroid) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: content,
      );
    }

    final hoverFill = KonataTheme.surfaceCardSubtleBorder(p);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: _hovered ? hoverFill : Colors.transparent,
            borderRadius: KonataTheme.borderRadiusCard,
          ),
          child: content,
        ),
      ),
    );
  }
}

/// 表单/列表分组区标题。
class KonataSectionLabel extends StatelessWidget {
  /// 创建分组标题。
  const KonataSectionLabel({
    super.key,
    required this.text,
    this.padding = const EdgeInsets.only(bottom: 8),
  });

  /// 标题文本。
  final String text;

  /// 外边距。
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: padding,
      child: Text(
        text,
        style: KonataTheme.captionStyle(
          p,
          fontSize: KonataTheme.fontSizeCaption,
        ),
      ),
    );
  }
}
