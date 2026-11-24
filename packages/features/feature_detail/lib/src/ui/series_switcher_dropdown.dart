import 'dart:async';

import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/series_member_label_resolver.dart';
import 'series_selector_sheet_dialog.dart';

/// 主操作行「系列胶囊」入口按钮：展示简洁系列摘要，点击后拉起三端自适应系列选择器。
class SeriesSwitcherDropdown extends StatelessWidget {
  /// 创建系列切换入口胶囊。
  const SeriesSwitcherDropdown({
    super.key,
    required this.seriesGroup,
    required this.members,
    required this.activeWork,
    required this.imageLoader,
    required this.onSelectWork,
    this.onDarkBackdrop = true,
    this.compact = false,
    this.useBottomSheet = false,
  });

  /// 当前所属系列分组（可为空）。
  final SeriesGroup? seriesGroup;

  /// 同系列作品列表（包含当前作品）。
  final List<Work> members;

  /// 当前详情页展示中的作品。
  final Work activeWork;

  /// 受管图片加载器。
  final ManagedImageLoader imageLoader;

  /// 切换到同系列其他作品时的回调。
  final ValueChanged<String> onSelectWork;

  /// 是否悬浮于深色背景原画之上（影响胶囊字体与边框对比度）。
  final bool onDarkBackdrop;

  /// 是否处于手机等紧凑视口宽度（启用紧凑摘要文案与宽度约束）。
  final bool compact;

  /// 点击胶囊后是否使用底部全宽毛玻璃抽屉（否则弹出居中宽毛玻璃弹窗）。
  final bool useBottomSheet;

  @override
  Widget build(BuildContext context) {
    if (members.length <= 1) {
      return const SizedBox.shrink();
    }

    final p = context.palette;
    final summaryLabel = SeriesMemberLabelResolver.resolveCapsuleSummary(
      members: members,
      activeWork: activeWork,
      seriesGroup: seriesGroup,
      compact: compact,
    );
    final foreground = onDarkBackdrop
        ? KonataTheme.overlayWhiteTextPeak
        : p.textPrimary;
    final muted = onDarkBackdrop
        ? KonataTheme.overlayWhiteTextSub
        : p.textSecondary;
    final fillColor = onDarkBackdrop
        ? const Color(0x36141820)
        : p.glassOverlay;
    final borderColor = onDarkBackdrop
        ? KonataTheme.overlayWhiteBorderStrong
        : p.hoverBorder;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        key: const Key('series_switcher_capsule'),
        onTap: () {
          unawaited(
            showSeriesSelectorModal(
              context,
              seriesGroup: seriesGroup,
              members: members,
              activeWork: activeWork,
              imageLoader: imageLoader,
              onSelectWork: onSelectWork,
              useBottomSheet: useBottomSheet,
            ),
          );
        },
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: 42,
            maxHeight: 44,
            maxWidth: compact ? 186 : 280,
          ),
          child: ClipRRect(
            borderRadius: KonataTheme.borderRadiusPill,
            child: BackdropFilter(
              filter: KonataTheme.blurFilterControl,
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: compact ? 12 : 16,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: fillColor,
                  borderRadius: KonataTheme.borderRadiusPill,
                  border: Border.all(color: borderColor),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.layers_rounded,
                      size: 16,
                      color: muted,
                    ),
                    const SizedBox(width: 7),
                    Flexible(
                      child: Text(
                        summaryLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: foreground,
                          fontSize: compact
                              ? KonataTheme.fontSizeCaption
                              : KonataTheme.fontSizeBody,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.1,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      Icons.keyboard_arrow_down_rounded,
                      size: 17,
                      color: muted,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
