import 'package:flutter/material.dart';

import '../../domain/formatting/media_display_formatter.dart';
import '../../domain/repositories/file_system_gateway.dart';
import '../theme/konata_palette.dart';
import '../widgets/design_system/konata_draggable_scrollbar.dart';
import '../widgets/design_system/konata_glass_dialog.dart';
import '../widgets/design_system/konata_pill_button.dart';
import '../widgets/design_system/konata_surface_card.dart';

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
    if (entry.isDirectory) {
      return InkWell(
        onTap: onEnterDirectory,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            children: [
              Checkbox(value: checked, onChanged: (_) => onToggleDirectory()),
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
                    fontSize: 13.5,
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
              style: TextStyle(color: p.textSecondary, fontSize: 13),
            ),
          ),
          if (sizeText.isNotEmpty) ...[
            const SizedBox(width: 10),
            Text(
              sizeText,
              style: TextStyle(
                color: p.textMuted,
                fontSize: 11.5,
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
        style: TextStyle(color: p.textSecondary, fontSize: 13, height: 1.55),
      ),
    ),
  );
}

/// 媒体源浏览器右侧「已选扫描范围」摘要与快速清理面板。
class SourceSelectedScopePanel extends StatelessWidget {
  /// 创建已选范围摘要面板。
  const SourceSelectedScopePanel({
    super.key,
    required this.selectedPaths,
    required this.busy,
    required this.onRemovePath,
    required this.onClearAll,
    required this.onShowHelp,
  });

  /// 当前已选的相对目录路径列表（已排序或原始集合）。
  final List<String> selectedPaths;

  /// 是否处于提交或扫描触发中。
  final bool busy;

  /// 移除单个已选目录回调。
  final ValueChanged<String> onRemovePath;

  /// 清空全部已选目录回调。
  final VoidCallback onClearAll;

  /// 查看多选规则说明回调。
  final VoidCallback onShowHelp;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    return KonataSurfaceCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      '已选目录',
                      style: TextStyle(
                        color: p.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (selectedPaths.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      Text(
                        '· ${selectedPaths.length}',
                        style: TextStyle(
                          color: p.textSecondary,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              IconButton(
                tooltip: '多选扫描说明',
                visualDensity: VisualDensity.compact,
                iconSize: 17,
                color: p.textSecondary,
                icon: const Icon(Icons.help_outline_rounded),
                onPressed: onShowHelp,
              ),
              if (selectedPaths.isNotEmpty)
                KonataPillButton.ghost(
                  label: '清空',
                  compact: true,
                  onPressed: busy ? null : onClearAll,
                ),
            ],
          ),
          const SizedBox(height: 8),
          Divider(height: 1, color: p.hairline),
          const SizedBox(height: 10),
          Expanded(
            child: selectedPaths.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.checklist_rtl_rounded,
                            size: 32,
                            color: p.textMuted,
                          ),
                          const SizedBox(height: 10),
                          Text(
                            '当前未勾选指定目录',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: p.textPrimary,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                : KonataDraggableScrollbar(
                    builder: (_, ctrl) => ListView.separated(
                      controller: ctrl,
                      padding: const EdgeInsets.only(right: 12),
                      itemCount: selectedPaths.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 6),
                      itemBuilder: (_, index) {
                        final path = selectedPaths[index];
                        final segments = path.split('/');
                        final name = segments.isEmpty ? path : segments.last;
                        return Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: p.softFill,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.folder_rounded,
                                size: 16,
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
                                        fontSize: 12.5,
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
                                          fontSize: 11,
                                          fontFamily: 'Consolas',
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 4),
                              InkWell(
                                borderRadius: BorderRadius.circular(6),
                                onTap: busy ? null : () => onRemovePath(path),
                                child: Padding(
                                  padding: const EdgeInsets.all(4),
                                  child: Icon(
                                    Icons.close_rounded,
                                    size: 15,
                                    color: p.textSecondary,
                                  ),
                                ),
                              ),
                            ],
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

/// 媒体源浏览器条目展示辅助工具（文件类型识别与大小格式化）。
abstract final class SourceBrowserFormatters {
  static const Set<String> _videoExts = {
    '.mkv',
    '.mp4',
    '.m2ts',
    '.avi',
    '.ts',
    '.webm',
  };
  static const Set<String> _subtitleExts = {
    '.ass',
    '.ssa',
    '.srt',
    '.sup',
    '.vtt',
  };
  static const Set<String> _audioExts = {
    '.flac',
    '.cue',
    '.mp3',
    '.m4a',
    '.wav',
    '.aac',
    '.ogg',
    '.opus',
  };

  /// 根据文件名返回语义化图标。
  static IconData iconForFile(String fileName) {
    final lower = fileName.toLowerCase();
    final dot = lower.lastIndexOf('.');
    final ext = dot == -1 ? '' : lower.substring(dot);
    if (_videoExts.contains(ext)) return Icons.movie_outlined;
    if (_subtitleExts.contains(ext)) return Icons.subtitles_outlined;
    if (_audioExts.contains(ext)) return Icons.music_note_outlined;
    if (ext == '.nfo') return Icons.description_outlined;
    return Icons.insert_drive_file_outlined;
  }

  /// 是否为视频文件（用于高亮图标颜色）。
  static bool isVideoFile(String fileName) {
    final lower = fileName.toLowerCase();
    final dot = lower.lastIndexOf('.');
    return dot != -1 && _videoExts.contains(lower.substring(dot));
  }

  /// 格式化字节数为人类可读大小。
  static String formatBytes(int? bytes) =>
      MediaDisplayFormatter.formatBytes(bytes);
}
