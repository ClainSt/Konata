import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';

/// 详情页内置齿轮菜单与外部动作扩展点统一动作标识。
enum DetailBuiltInGearAction {
  /// 重新抓取作品元数据与艺术图。
  rescrape,

  /// 同步所在源目录新增或删除的文件。
  syncDirectory,

  /// 编辑海报封面。
  editPoster,

  /// 编辑横版背景原画。
  editBackdrop,

  /// 编辑竖版无字原画。
  editPortraitBackdrop,

  /// 编辑透明标题徽标。
  editLogo,

  /// 手动编辑信息与文件映射。
  manualEdit,

  /// 手动精确纠错匹配。
  manualMatch,

  /// 管理系列编组。
  manageSeries,

  /// 并入库内其他作品。
  mergeIntoWork,

  /// 一键标为全部已看完。
  markAllWatched,

  /// 清空播放进度。
  clearHistory,

  /// 隐藏或恢复显示作品。
  toggleHidden,

  /// 从媒体库移除记录。
  deleteFromLibrary,
}

/// 详情页主舞台右上/动作栏统一齿轮「更多」菜单触发器（严格通过 `showKonataGlassMenu` 弹出）。
///
/// 同时聚合内置管理操作与外部 Feature 通过 [DetailActionContribution] 注入的扩展菜单项。
class DetailGearMenu extends StatelessWidget {
  /// 创建详情页更多动作齿轮菜单。
  const DetailGearMenu({
    super.key,
    required this.work,
    required this.onBuiltInAction,
    this.externalActions = const <DetailActionContribution>[],
    this.onInvokeExternalAction,
    this.compact = false,
  });

  /// 当前作品领域实体。
  final Work work;

  /// 触发内置菜单动作回调。
  final ValueChanged<DetailBuiltInGearAction> onBuiltInAction;

  /// 动态注入的外部 `gearMenu` 扩展动作清单。
  final List<DetailActionContribution> externalActions;

  /// 触发外部扩展动作回调。
  final ValueChanged<DetailActionContribution>? onInvokeExternalAction;

  /// 是否使用紧凑触发胶囊样式。
  final bool compact;

  Future<void> _openMenu(BuildContext anchorContext) async {
    const extPrefix = '__ext__::';
    final items = <KonataGlassMenuItem<String>>[
      const KonataGlassMenuItem<String>(
        value: 'rescrape',
        label: '重新抓取元数据',
        icon: Icons.refresh_rounded,
      ),
      const KonataGlassMenuItem<String>(
        value: 'syncDirectory',
        label: '刷新源目录变更',
        icon: Icons.sync_rounded,
      ),
      const KonataGlassMenuItem<String>(
        value: 'manualEdit',
        label: '手动编辑信息与分集',
        icon: Icons.edit_outlined,
      ),
      const KonataGlassMenuItem<String>(
        value: 'manualMatch',
        label: '手动精确匹配',
        icon: Icons.manage_search_rounded,
      ),
      const KonataGlassMenuItem<String>(
        value: 'manageSeries',
        label: '管理系列编组',
        icon: Icons.collections_bookmark_outlined,
      ),
      const KonataGlassMenuItem<String>(
        value: 'mergeIntoWork',
        label: '并入库内其他作品',
        icon: Icons.merge_type_rounded,
      ),
      const KonataGlassMenuItem<String>(
        value: 'editPoster',
        label: '编辑封面海报',
        icon: Icons.photo_outlined,
      ),
      const KonataGlassMenuItem<String>(
        value: 'editBackdrop',
        label: '编辑横版背景原画 / 抽帧',
        icon: Icons.wallpaper_outlined,
      ),
      const KonataGlassMenuItem<String>(
        value: 'editLogo',
        label: '编辑透明标题徽标',
        icon: Icons.title_rounded,
      ),
      for (final ext in externalActions)
        KonataGlassMenuItem<String>(
          key: ValueKey<String>('detail_ext_gear_${ext.id}'),
          value: '$extPrefix${ext.id}',
          label: ext.label,
          icon: KonataIconRegistry.resolve(ext.iconKey),
        ),
      const KonataGlassMenuItem<String>(
        value: 'markAllWatched',
        label: '全剧标为已看完',
        icon: Icons.done_all_rounded,
      ),
      const KonataGlassMenuItem<String>(
        value: 'clearHistory',
        label: '清空观看进度',
        icon: Icons.history_toggle_off_rounded,
      ),
      KonataGlassMenuItem<String>(
        value: 'toggleHidden',
        label: work.isHidden ? '从隐藏中恢复展示' : '从主媒体库隐藏',
        icon: work.isHidden
            ? Icons.visibility_outlined
            : Icons.visibility_off_outlined,
      ),
      const KonataGlassMenuItem<String>(
        value: 'deleteFromLibrary',
        label: '从媒体库移除记录',
        icon: Icons.delete_outline_rounded,
        isDanger: true,
      ),
    ];

    final picked = await showKonataGlassMenu<String>(
      anchorContext: anchorContext,
      items: items,
      minWidth: 212,
    );
    if (picked == null) return;
    if (picked.startsWith(extPrefix)) {
      final targetId = picked.substring(extPrefix.length);
      for (final ext in externalActions) {
        if (ext.id == targetId) {
          onInvokeExternalAction?.call(ext);
          break;
        }
      }
      return;
    }

    final action = switch (picked) {
      'rescrape' => DetailBuiltInGearAction.rescrape,
      'syncDirectory' => DetailBuiltInGearAction.syncDirectory,
      'editPoster' => DetailBuiltInGearAction.editPoster,
      'editBackdrop' => DetailBuiltInGearAction.editBackdrop,
      'editPortraitBackdrop' => DetailBuiltInGearAction.editPortraitBackdrop,
      'editLogo' => DetailBuiltInGearAction.editLogo,
      'manualEdit' => DetailBuiltInGearAction.manualEdit,
      'manualMatch' => DetailBuiltInGearAction.manualMatch,
      'manageSeries' => DetailBuiltInGearAction.manageSeries,
      'mergeIntoWork' => DetailBuiltInGearAction.mergeIntoWork,
      'markAllWatched' => DetailBuiltInGearAction.markAllWatched,
      'clearHistory' => DetailBuiltInGearAction.clearHistory,
      'toggleHidden' => DetailBuiltInGearAction.toggleHidden,
      'deleteFromLibrary' => DetailBuiltInGearAction.deleteFromLibrary,
      _ => null,
    };
    if (action != null) {
      onBuiltInAction(action);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final side = compact ? 36.0 : 40.0;
    return Builder(
      builder: (anchorContext) => DecoratedBox(
        decoration: BoxDecoration(
          color: KonataPlaybackTokens.glassSurface(p),
          shape: BoxShape.circle,
          border: Border.all(
            color: KonataPlaybackTokens.glassBorder(p),
            width: 0.9,
          ),
        ),
        child: KonataCapsuleIconButton(
          key: const Key('detail_gear_menu_button'),
          icon: Icons.tune_rounded,
          tooltip: '更多操作与管理',
          color: p.textPrimary,
          size: compact ? 18 : 20,
          fixedSize: side,
          onTap: () => _openMenu(anchorContext),
        ),
      ),
    );
  }
}
