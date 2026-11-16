import 'package:flutter/material.dart';

import '../../theme/konata_palette.dart';
import '../../theme/konata_theme.dart';

/// 全站唯一四大主页面一级页头组件（`媒体库` / `媒体源` / `播放记录` / `设置` 共同调用）。
///
/// 锁定与顶部导航栏首项 `媒体库` 文字左边缘对齐（[KonataTheme.pageHorizontalPadding] = `30px`），
/// 锁定顶距（`16px`）与固定行高（`44px`），确保切换任意主页面及右侧操作槽有无按钮时，
/// 左侧主标题的 X / Y 坐标恒定零像素跳动。
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

  /// 可选右侧操作区按钮集合（右边缘严格对齐至 `W - 30px`）。
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        KonataTheme.pageHorizontalPadding,
        KonataTheme.pageHeaderTopSpacing,
        KonataTheme.pageHorizontalPadding,
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
}
