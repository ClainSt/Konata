import 'package:material_ui/material_ui.dart';

import '../tokens/konata_adaptive_tokens.dart';
import '../tokens/konata_palette.dart';
import '../tokens/konata_theme.dart';

/// 全站唯一四大主页面一级页头组件（`媒体库` / `媒体源` / `播放记录` / `设置` 共同调用）。
///
/// 桌面与宽视口锁定与顶部导航栏首项 `媒体库` 文字左边缘对齐（[KonataTheme.pageHorizontalPadding] = `30px`），
/// 锁定顶距（`16px`）与固定行高（`44px`），确保切换任意主页面及右侧操作槽有无按钮时主标题零像素跳动；
/// 窄视口自动切换紧凑边距与弹性折行，杜绝触屏大热区横向溢出。
class KonataPageHeader extends StatelessWidget {
  /// 创建统一一级页头。
  const KonataPageHeader({
    super.key,
    required this.title,
    this.badge,
    this.actions = const [],
  });

  /// 左侧主标题文案（26px / w600）。
  final String title;

  /// 可选紧邻主标题右侧的统计徽章（如作品总数胶囊）。
  final Widget? badge;

  /// 可选右侧操作区按钮集合。
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact =
            KonataAdaptiveTokens.isAndroid &&
            constraints.maxWidth < KonataAdaptiveTokens.tabletBreakpoint;
        final horizontalPad = compact
            ? KonataAdaptiveTokens.horizontalInset
            : KonataTheme.pageHorizontalPadding;

        if (!compact && constraints.maxWidth >= 680) {
          return Padding(
            padding: EdgeInsets.fromLTRB(
              horizontalPad,
              KonataTheme.pageHeaderTopSpacing,
              horizontalPad,
              KonataTheme.pageHeaderBottomSpacing,
            ),
            child: SizedBox(
              height: KonataTheme.pageHeaderHeight,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    softWrap: false,
                    style: KonataTheme.h1Style(p),
                  ),
                  if (badge != null) ...[
                    const SizedBox(width: 12),
                    badge!,
                  ],
                  const Spacer(),
                  for (var i = 0; i < actions.length; i++) ...[
                    if (i > 0) const SizedBox(width: 10),
                    actions[i],
                  ],
                ],
              ),
            ),
          );
        }

        return Padding(
          padding: EdgeInsets.fromLTRB(
            horizontalPad,
            KonataAdaptiveTokens.safeGap,
            horizontalPad,
            KonataAdaptiveTokens.safeGap,
          ),
          child: Wrap(
            spacing: 10,
            runSpacing: 8,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: KonataTheme.h1Style(p),
                    ),
                  ),
                  if (badge != null) ...[
                    const SizedBox(width: 10),
                    Flexible(child: badge!),
                  ],
                ],
              ),
              if (actions.isNotEmpty)
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: actions,
                ),
            ],
          ),
        );
      },
    );
  }
}
