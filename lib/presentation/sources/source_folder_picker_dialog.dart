import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/source_actions_provider.dart';
import '../../domain/models/media_source.dart';
import '../../domain/repositories/file_system_gateway.dart';
import '../theme/konata_adaptive_tokens.dart';
import '../theme/konata_palette.dart';
import '../widgets/design_system/konata_draggable_scrollbar.dart';
import '../widgets/design_system/konata_glass_dialog.dart';
import '../widgets/design_system/konata_pill_button.dart';
import '../widgets/design_system/konata_soft_text_field.dart';
import '../widgets/design_system/konata_surface_card.dart';
import 'source_selected_scope_panel.dart';

enum _FolderPickerViewMode { browse, selectedManage }

/// 媒体源目录浏览、搜索与多选刮削毛玻璃弹窗（支持本地 / WebDAV / SMB 统一浏览）。
class SourceFolderPickerDialog extends ConsumerStatefulWidget {
  /// 创建媒体源浏览与多选目录弹窗。
  const SourceFolderPickerDialog({
    super.key,
    required this.source,
    this.onScanSelected,
  });

  /// 当前配置的媒体源。
  final MediaSource source;

  /// 立即以当前勾选路径集合启动扫描的回调（空列表表示扫描全库）。
  final Future<void> Function(List<String> selectedPaths)? onScanSelected;

  @override
  ConsumerState<SourceFolderPickerDialog> createState() =>
      _SourceFolderPickerDialogState();
}

class _SourceFolderPickerDialogState
    extends ConsumerState<SourceFolderPickerDialog> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  final ScrollController _listScrollCtrl = ScrollController();
  final Set<String> _selectedPaths = <String>{};
  _FolderPickerViewMode _viewMode = _FolderPickerViewMode.browse;
  String _currentPath = '';
  String _searchQuery = '';
  List<RemoteEntry> _entries = const [];
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadDirectory('');
  }

  @override
  void dispose() {
    _listScrollCtrl.dispose();
    _searchFocusNode.dispose();
    _searchController.dispose();
    super.dispose();
  }

  String _normalizePath(String raw) {
    return raw.trim().replaceAll('\\', '/').replaceAll(RegExp(r'^/+|/+$'), '');
  }

  Future<void> _loadDirectory(String path) async {
    final normalized = _normalizePath(path);
    setState(() {
      _loading = true;
      _error = null;
      _currentPath = normalized;
      _searchQuery = '';
      _searchController.clear();
    });
    try {
      final list = await ref
          .read(konataActionsProvider)
          .listSourceDirectory(widget.source, normalized);
      final sorted = List<RemoteEntry>.of(list)
        ..sort((a, b) {
          if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        });
      if (!mounted) return;
      setState(() {
        _entries = sorted;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '读取目录失败: $e';
        _loading = false;
      });
    }
  }

  void _navigateUp() {
    if (_currentPath.isEmpty) return;
    final parts = _currentPath.split('/')..removeLast();
    _loadDirectory(parts.join('/'));
  }

  void _togglePath(String relativePath) {
    final norm = _normalizePath(relativePath);
    if (norm.isEmpty) return;
    setState(() {
      if (!_selectedPaths.remove(norm)) {
        _selectedPaths.add(norm);
      }
    });
  }

  void _removePathsBatch(List<String> paths) {
    if (paths.isEmpty) return;
    setState(() {
      for (final raw in paths) {
        _selectedPaths.remove(_normalizePath(raw));
      }
    });
  }

  Future<void> _scanNow() async {
    final callback = widget.onScanSelected;
    if (callback == null) return;
    setState(() => _busy = true);
    final targets = _selectedPaths.toList()..sort();
    Navigator.of(context).pop();
    await callback(targets);
  }

  List<RemoteEntry> get _filteredEntries {
    final q = _searchQuery.trim().toLowerCase();
    if (q.isEmpty) return _entries;
    return _entries
        .where((e) => e.name.toLowerCase().contains(q))
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final sortedSelected = _selectedPaths.toList()..sort();
    final filtered = _filteredEntries;

    return KonataGlassDialog(
      width: 940,
      maxHeight: 640,
      title: '浏览与多选目录 · ${widget.source.label}',
      onClose: _busy ? () {} : () => Navigator.of(context).pop(),
      actions: [
        KonataPillButton.ghost(
          label: '取消',
          compact: true,
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
        ),
        if (widget.onScanSelected != null)
          KonataPillButton.primary(
            label: sortedSelected.isNotEmpty
                ? '扫描所选目录 (${sortedSelected.length})'
                : '扫描全库',
            icon: Icons.radar_rounded,
            compact: true,
            onPressed: _busy ? null : _scanNow,
          ),
      ],
      child: LayoutBuilder(
        builder: (dialogCtx, outerConstraints) {
          final targetH = outerConstraints.maxHeight.isFinite
              ? math.min(488.0, outerConstraints.maxHeight)
              : 488.0;
          final landscapeCompact =
              KonataGlassDialog.isLandscapeCompactInputActive(dialogCtx);

          return SizedBox(
            height: targetH,
            child: _viewMode == _FolderPickerViewMode.selectedManage
                ? SourceSelectedScopePanel(
                    selectedPaths: sortedSelected,
                    busy: _busy,
                    onBackToBrowse: () => setState(
                      () => _viewMode = _FolderPickerViewMode.browse,
                    ),
                    onRemovePath: _togglePath,
                    onRemovePathsBatch: _removePathsBatch,
                    onClearAll: () => setState(() => _selectedPaths.clear()),
                    onShowHelp: () => showSourceBrowserHelpDialog(dialogCtx),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildTopControls(
                        p,
                        filtered.length,
                        landscapeCompact: landscapeCompact,
                      ),
                      Offstage(
                        offstage: landscapeCompact,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(height: 8),
                            _buildSelectedEntryBar(
                              p,
                              selectedCount: sortedSelected.length,
                            ),
                          ],
                        ),
                      ),
                      SizedBox(height: landscapeCompact ? 6 : 8),
                      Expanded(
                        child: KonataSurfaceCard(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: _buildEntryList(p, filtered),
                        ),
                      ),
                    ],
                  ),
          );
        },
      ),
    );
  }

  Widget _buildSelectedEntryBar(
    KonataPalette p, {
    required int selectedCount,
  }) {
    final minH = KonataAdaptiveTokens.isAndroid
        ? KonataAdaptiveTokens.touchTarget
        : 40.0;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        key: const ValueKey('source_selected_scope_entry'),
        borderRadius: BorderRadius.circular(12),
        onTap: _busy
            ? null
            : () => setState(
                () => _viewMode = _FolderPickerViewMode.selectedManage,
              ),
        child: Container(
          constraints: BoxConstraints(minHeight: minH),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: selectedCount > 0
                ? p.accent.withValues(alpha: 0.10)
                : p.softFill,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selectedCount > 0
                  ? p.accent.withValues(alpha: 0.36)
                  : p.hairline,
            ),
          ),
          child: Row(
            children: [
              Icon(
                Icons.folder_copy_outlined,
                size: 18,
                color: selectedCount > 0 ? p.accent : p.textSecondary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  selectedCount > 0
                      ? '已选目录 · $selectedCount'
                      : '已选目录 · 0（点击管理或默认扫描整源）',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: p.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              IconButton(
                tooltip: '多选扫描说明',
                visualDensity: VisualDensity.compact,
                iconSize: 17,
                color: p.textSecondary,
                icon: const Icon(Icons.help_outline_rounded),
                onPressed: () => showSourceBrowserHelpDialog(context),
              ),
              if (selectedCount > 0) ...[
                KonataPillButton.ghost(
                  label: '清空',
                  compact: true,
                  onPressed: _busy
                      ? null
                      : () => setState(() => _selectedPaths.clear()),
                ),
                const SizedBox(width: 2),
              ],
              Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: p.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopControls(
    KonataPalette p,
    int visibleCount, {
    bool landscapeCompact = false,
  }) {
    final crumbs = _currentPath.isEmpty
        ? const <String>[]
        : _currentPath.split('/').where((s) => s.isNotEmpty).toList();
    final currentChecked =
        _currentPath.isNotEmpty && _selectedPaths.contains(_currentPath);

    return Column(
      children: [
        Offstage(
          offstage: landscapeCompact,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  KonataPillButton.secondary(
                    label: '上级',
                    icon: Icons.arrow_upward_rounded,
                    compact: true,
                    onPressed: _loading || _currentPath.isEmpty
                        ? null
                        : _navigateUp,
                  ),
                  const SizedBox(width: 8),
                  Tooltip(
                    message: _currentPath.isEmpty
                        ? '处于根目录（未勾选子目录即代表全库扫描）'
                        : '勾选/取消勾选当前目录',
                    child: Checkbox(
                      value: currentChecked,
                      onChanged: _currentPath.isEmpty
                          ? null
                          : (_) => _togglePath(_currentPath),
                    ),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          _crumbButton(
                            p: p,
                            label: '根目录',
                            active: _currentPath.isEmpty,
                            onTap: _loading ? null : () => _loadDirectory(''),
                          ),
                          for (var i = 0; i < crumbs.length; i++) ...[
                            Text(
                              '/',
                              style: TextStyle(color: p.textMuted, fontSize: 12),
                            ),
                            _crumbButton(
                              p: p,
                              label: crumbs[i],
                              active: i == crumbs.length - 1,
                              onTap: _loading
                                  ? null
                                  : () => _loadDirectory(
                                      crumbs.sublist(0, i + 1).join('/'),
                                    ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _searchQuery.isEmpty
                        ? '${_entries.length} 项'
                        : '匹配 $visibleCount / ${_entries.length}',
                    style: TextStyle(
                      color: p.textSecondary,
                      fontSize: 12,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
        KonataSoftTextField(
          controller: _searchController,
          focusNode: _searchFocusNode,
          dense: true,
          prefixIcon: Icons.search_rounded,
          hintText: '过滤当前目录下的文件夹或媒体文件...',
          suffix: _searchQuery.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.close_rounded, size: 16),
                  color: p.textSecondary,
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _searchQuery = '');
                  },
                )
              : null,
          onChanged: (v) => setState(() => _searchQuery = v),
        ),
      ],
    );
  }

  Widget _crumbButton({
    required KonataPalette p,
    required String label,
    required bool active,
    required VoidCallback? onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Text(
          label,
          style: TextStyle(
            color: active ? p.textPrimary : p.textSecondary,
            fontSize: 12.5,
            fontWeight: active ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _buildEntryList(KonataPalette p, List<RemoteEntry> entries) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: p.danger, fontSize: 13),
              ),
              const SizedBox(height: 10),
              KonataPillButton.secondary(
                label: '重试',
                compact: true,
                onPressed: () => _loadDirectory(_currentPath),
              ),
            ],
          ),
        ),
      );
    }
    if (entries.isEmpty) {
      return Center(
        child: Text(
          _searchQuery.isNotEmpty ? '没有匹配当前筛选条件的条目' : '该目录为空',
          style: TextStyle(color: p.textSecondary, fontSize: 13),
        ),
      );
    }

    return KonataDraggableScrollbar(
      controller: _listScrollCtrl,
      builder: (_, ctrl) => ListView.separated(
        controller: ctrl,
        padding: const EdgeInsets.only(right: 12),
        itemCount: entries.length,
        separatorBuilder: (_, _) =>
            Divider(height: 1, color: p.hairline, indent: 14, endIndent: 14),
        itemBuilder: (_, index) {
          final entry = entries[index];
          final rel = _normalizePath(entry.relativePath);
          return SourceBrowserEntryRow(
            entry: entry,
            checked: entry.isDirectory && _selectedPaths.contains(rel),
            onEnterDirectory: () => _loadDirectory(rel),
            onToggleDirectory: () => _togglePath(rel),
          );
        },
      ),
    );
  }
}
