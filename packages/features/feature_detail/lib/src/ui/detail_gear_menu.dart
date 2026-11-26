import 'package:flutter/widgets.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';

/// 详情页内置管理动作及其固定展示顺序。
enum DetailBuiltInGearAction {
  rescrape('重新抓取数据', Icons.refresh_rounded),
  manualEdit('手动编辑信息', Icons.edit_outlined),
  manualMatch('手动精确匹配', Icons.manage_search_rounded),
  manageSeries('管理系列编组', Icons.collections_bookmark_outlined),
  mergeIntoWork('并入其他作品', Icons.merge_type_rounded),
  editPoster('编辑封面海报', Icons.photo_outlined),
  editBackdrop('编辑横版背景', Icons.wallpaper_outlined),
  editLogo('编辑标题徽标', Icons.title_rounded),
  deleteFromLibrary('移除这部作品', Icons.delete_outline_rounded);

  const DetailBuiltInGearAction(this.label, this.icon);

  final String label;
  final IconData icon;
}

/// 详情页统一管理菜单触发器，保留声明式外部动作扩展契约。
class DetailGearMenu extends StatelessWidget {
  const DetailGearMenu({
    super.key,
    required this.onBuiltInAction,
    this.externalActions = const <DetailActionContribution>[],
    this.onInvokeExternalAction,
    this.compact = false,
  });

  final ValueChanged<DetailBuiltInGearAction> onBuiltInAction;
  final List<DetailActionContribution> externalActions;
  final ValueChanged<DetailActionContribution>? onInvokeExternalAction;
  final bool compact;

  Future<void> _openMenu(BuildContext anchorContext) async {
    final picked = await showKonataGlassMenu<Object>(
      anchorContext: anchorContext,
      items: [
        for (final action in DetailBuiltInGearAction.values)
          if (action != DetailBuiltInGearAction.deleteFromLibrary)
            KonataGlassMenuItem<Object>(
              value: action,
              label: action.label,
              icon: action.icon,
            ),
        for (final ext in externalActions)
          KonataGlassMenuItem<Object>(
            key: ValueKey<String>('detail_ext_gear_${ext.id}'),
            value: ext,
            label: ext.label,
            icon: KonataIconRegistry.resolve(ext.iconKey),
          ),
        KonataGlassMenuItem<Object>(
          value: DetailBuiltInGearAction.deleteFromLibrary,
          label: DetailBuiltInGearAction.deleteFromLibrary.label,
          icon: DetailBuiltInGearAction.deleteFromLibrary.icon,
          isDanger: true,
        ),
      ],
      minWidth: 212,
    );
    if (picked is DetailBuiltInGearAction) {
      onBuiltInAction(picked);
    } else if (picked is DetailActionContribution) {
      onInvokeExternalAction?.call(picked);
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
          tooltip: '管理作品',
          color: p.textPrimary,
          size: compact ? 18 : 20,
          fixedSize: side,
          onTap: () => _openMenu(anchorContext),
        ),
      ),
    );
  }
}
