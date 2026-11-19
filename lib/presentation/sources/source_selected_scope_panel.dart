import 'package:flutter/material.dart';

import '../../domain/formatting/media_display_formatter.dart';
import '../../domain/models/media_extensions.dart';
import '../../domain/repositories/file_system_gateway.dart';
import '../theme/konata_palette.dart';
import '../widgets/design_system/konata_draggable_scrollbar.dart';
import '../widgets/design_system/konata_glass_dialog.dart';
import '../widgets/design_system/konata_pill_button.dart';
import '../widgets/design_system/konata_surface_card.dart';
import '../theme/konata_theme.dart';

/// 媒体源浏览器单行条目组件（目录带勾选与钻取，文件带类型图标与大小）。
class SourceBrowserEntryRow extends StatelessWidget {
  /// 创建目录或文件列表项。
  const SourceBrowserEntryRow({
    super.key,
    required this.entry,
    required this.checked,
    required this.onEnterDirectory,
    required this.onToggleDirectory,
  });

  /// 当前目录项模型。
  final RemoteEntry entry;

  /// 是否已被勾选（仅目录有效）。
  final bool checked;

  /// 点击文件夹钻取回调。
  final VoidCallback onEnterDirectory;

  /// 点击复选框切换勾选回调。
  final VoidCallback onToggleDirectory;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final shortLandscape = MediaQuery.sizeOf(context).height < 500;
    if (entry.isDirectory) {
      return InkWell(
        onTap: onEnterDirectory,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 10,
            vertical: shortLandscape ? 2 : 6,
          ),
          child: Row(
            children: [
              Checkbox(
                visualDensity: shortLandscape ? VisualDensity.compact : null,
                value: checked,
                onChanged: (_) => onToggleDirectory(),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.folder_rounded,
                size: 18,
                color: checked ? p.accent : p.textSecondary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  entry.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: p.textPrimary,
                    fontSize: KonataTheme.fontSizeBody,
                    fontWeight: checked ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
              Icon(Icons.chevron_right_rounded, size: 18, color: p.textMuted),
            ],
          ),
        ),
      );
    }

    final isVideo = SourceBrowserFormatters.isVideoFile(entry.name);
    final sizeText = SourceBrowserFormatters.formatBytes(entry.size);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      child: Row(
        children: [
          const SizedBox(width: 24),
          Icon(
            SourceBrowserFormatters.iconForFile(entry.name),
            size: 17,
            color: isVideo ? p.accent : p.textMuted,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              entry.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: p.textSecondary, fontSize: KonataTheme.fontSizeBodySm),
            ),
          ),
          if (sizeText.isNotEmpty) ...[
            const SizedBox(width: 10),
            Text(
              sizeText,
              style: TextStyle(
                color: p.textMuted,
                fontSize: KonataTheme.fontSizeCaptionSm,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 弹出「多选目录扫描规则」说明浮层。
void showSourceBrowserHelpDialog(BuildContext context) {
  final p = context.palette;
  showKonataGlassDialog<void>(
    context: context,
    builder: (ctx) => KonataGlassDialog(
      width: 440,
      title: '多选目录扫描说明',
      actions: [
        KonataPillButton.primary(
          label: '知道了',
          compact: true,
          onPressed: () => Navigator.of(ctx).pop(),
        ),
      ],
      child: Text(
        '1. 勾选一个或多个文件夹后，右侧面板会实时汇总已选范围。\n'
        '2. 勾选子目录后点击「扫描所选目录 (N)」仅针对已选目录执行文件遍历与刮削，不会误删同源下未扫描文件夹的已有作品。\n'
        '3. 未勾选任何目录时，点击「扫描全库」将遍历整个媒体源根目录。\n'
        '4. 同时选中父目录与子目录时，后台扫描器会自动去重。',
        style: TextStyle(color: p.textSecondary, fontSize: KonataTheme.fontSizeBodySm, height: 1.55),
      ),
    ),
  );
}

/// 媒体源浏览弹窗「已选目录管理视图」（支持整窗切换与双栏常驻，统一通过勾选配合全选/反选/批量移除）。
class SourceSelectedScopePanel extends StatefulWidget {
  /// 创建已选目录管理视图。
  const SourceSelectedScopePanel({
    super.key,
    required this.selectedPaths,
    required this.busy,
    required this.onBackToBrowse,
    required this.onRemovePathsBatch,
    required this.onShowHelp,
    this.showBackButton = true,
  });

  /// 当前已选的相对目录路径列表（已排序）。
  final List<String> selectedPaths;

  /// 是否处于提交或扫描触发中。
  final bool busy;

  /// 返回浏览目录视图回调（整窗切换模式下使用）。
  final VoidCallback onBackToBrowse;

  /// 批量移除多个已选目录回调。
  final ValueChanged<List<String>> onRemovePathsBatch;

  /// 查看多选规则说明回调。
  final VoidCallback onShowHelp;

  /// 是否展示左上角「返回浏览目录」按钮（双栏常驻模式下隐藏）。
  final bool showBackButton;

  @override
  State<SourceSelectedScopePanel> createState() =>
      _SourceSelectedScopePanelState();
}

class _SourceSelectedScopePanelState extends State<SourceSelectedScopePanel> {
  final ScrollController _scrollCtrl = ScrollController();
  final Set<String> _checkedPaths = <String>{};

  @override
  void didUpdateWidget(covariant SourceSelectedScopePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final currentSet = widget.selectedPaths.toSet();
    _checkedPaths.removeWhere((p) => !currentSet.contains(p));
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _toggleChecked(String path) {
    setState(() {
      if (!_checkedPaths.remove(path)) {
        _checkedPaths.add(path);
      }
    });
  }

  void _selectAll() {
    setState(() {
      _checkedPaths
        ..clear()
        ..addAll(widget.selectedPaths);
    });
  }

  void _invertSelection() {
    setState(() {
      final next = <String>{};
      for (final path in widget.selectedPaths) {
        if (!_checkedPaths.contains(path)) {
          next.add(path);
        }
      }
      _checkedPaths
        ..clear()
        ..addAll(next);
    });
  }

  void _removeCheckedBatch() {
    if (_checkedPaths.isEmpty || widget.busy) return;
    final targets = _checkedPaths.toList(growable: false);
    setState(() => _checkedPaths.clear());
    widget.onRemovePathsBatch(targets);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final checkedCount = _checkedPaths.length;
    final shortLandscape = MediaQuery.sizeOf(context).height < 500;

    final helpButton = IconButton(
      key: const ValueKey('source_scope_help_button'),
      tooltip: '多选扫描说明',
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      padding: const EdgeInsets.all(4),
      iconSize: 18,
      color: p.textSecondary,
      icon: const Icon(Icons.help_outline_rounded),
      onPressed: widget.onShowHelp,
    );

    final batchButtons = <Widget>[
      if (widget.selectedPaths.isNotEmpty) ...[
        KonataPillButton.ghost(
          label: '全选',
          compact: true,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          onPressed: widget.busy ? null : _selectAll,
        ),
        const SizedBox(width: 2),
        KonataPillButton.ghost(
          label: '反选',
          compact: true,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          onPressed: widget.busy ? null : _invertSelection,
        ),
        const SizedBox(width: 2),
        KonataPillButton.secondary(
          label: checkedCount > 0 ? '移除 ($checkedCount)' : '移除',
          compact: true,
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          onPressed: (widget.busy || checkedCount == 0)
              ? null
              : _removeCheckedBatch,
        ),
      ],
    ];

    return KonataSurfaceCard(
      padding: EdgeInsets.all(shortLandscape ? 8 : 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.showBackButton) ...[
            Row(
              children: [
                KonataPillButton.secondary(
                  key: const ValueKey('source_scope_back_to_browse'),
                  label: '返回浏览目录',
                  icon: Icons.arrow_back_rounded,
                  compact: true,
                  onPressed: widget.busy ? null : widget.onBackToBrowse,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '已选目录 · ${widget.selectedPaths.length}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: p.textPrimary,
                      fontSize: KonataTheme.fontSizeBody,
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                helpButton,
              ],
            ),
            if (batchButtons.isNotEmpty) ...[
              const SizedBox(height: 6),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: batchButtons),
              ),
            ],
          ] else
            Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        Text(
                          '已选目录 · ${widget.selectedPaths.length}',
                          style: TextStyle(
                            color: p.textPrimary,
                            fontSize: KonataTheme.fontSizeBodySm,
                            fontWeight: FontWeight.w700,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                        if (batchButtons.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          ...batchButtons,
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                helpButton,
              ],
            ),
          SizedBox(height: shortLandscape ? 4 : 6),
          Divider(height: 1, color: p.hairline),
          SizedBox(height: shortLandscape ? 6 : 8),
          Expanded(
            child: widget.selectedPaths.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.checklist_rtl_rounded,
                            size: shortLandscape ? 26 : 32,
                            color: p.textMuted,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '当前未勾选指定目录（默认扫描整源）',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: p.textPrimary,
                              fontSize: KonataTheme.fontSizeBodyXs,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (widget.showBackButton) ...[
                            const SizedBox(height: 10),
                            KonataPillButton.secondary(
                              label: '去浏览并勾选目录',
                              compact: true,
                              onPressed:
                                  widget.busy ? null : widget.onBackToBrowse,
                            ),
                          ],
                        ],
                      ),
                    ),
                  )
                : KonataDraggableScrollbar(
                    controller: _scrollCtrl,
                    builder: (_, ctrl) => ListView.separated(
                      controller: ctrl,
                      padding: const EdgeInsets.only(right: 4),
                      itemCount: widget.selectedPaths.length,
                      separatorBuilder: (_, _) =>
                          SizedBox(height: shortLandscape ? 4 : 6),
                      itemBuilder: (_, index) {
                        final path = widget.selectedPaths[index];
                        final checked = _checkedPaths.contains(path);
                        final segments = path.split('/');
                        final name = segments.isEmpty ? path : segments.last;
                        return InkWell(
                          borderRadius: KonataTheme.borderRadiusControl,
                          onTap: widget.busy ? null : () => _toggleChecked(path),
                          child: Container(
                            width: double.infinity,
                            padding: EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: shortLandscape ? 3 : 8,
                            ),
                            decoration: BoxDecoration(
                              color: checked
                                  ? p.accent.withValues(alpha: 0.14)
                                  : p.softFill,
                              borderRadius: KonataTheme.borderRadiusControl,
                              border: Border.all(
                                color: checked
                                    ? p.accent.withValues(alpha: 0.45)
                                    : p.hairline,
                              ),
                            ),
                            child: Row(
                              children: [
                                Checkbox(
                                  visualDensity: shortLandscape
                                      ? VisualDensity.compact
                                      : null,
                                  value: checked,
                                  onChanged: widget.busy
                                      ? null
                                      : (_) => _toggleChecked(path),
                                ),
                                Icon(
                                  Icons.folder_rounded,
                                  size: 18,
                                  color: p.accent,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: p.textPrimary,
                                          fontSize: KonataTheme.fontSizeBodySm,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      if (path != name)
                                        Text(
                                          path,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: p.textMuted,
                                            fontSize: KonataTheme.fontSizeCaptionSm,
                                            fontFamily: 'Consolas',
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// 媒体源浏览器条目展示辅助工具（文件类型识别与大小格式化，复用领域层权威扩展名白名单）。
abstract final class SourceBrowserFormatters {
  /// 根据文件名返回语义化图标。
  static IconData iconForFile(String fileName) {
    final ext = KonataMediaExtensions.extensionOf(fileName);
    if (KonataMediaExtensions.video.contains(ext)) return Icons.movie_outlined;
    if (KonataMediaExtensions.subtitle.contains(ext)) {
      return Icons.subtitles_outlined;
    }
    if (KonataMediaExtensions.scannableAudio.contains(ext)) {
      return Icons.music_note_outlined;
    }
    if (KonataMediaExtensions.scanImage.contains(ext)) {
      return Icons.image_outlined;
    }
    if (ext == '.nfo') return Icons.description_outlined;
    return Icons.insert_drive_file_outlined;
  }

  /// 是否为视频文件（用于高亮图标颜色）。
  static bool isVideoFile(String fileName) =>
      KonataMediaExtensions.isVideoFile(fileName);

  /// 格式化字节数为人类可读大小。
  static String formatBytes(int? bytes) =>
      MediaDisplayFormatter.formatBytes(bytes);
}
