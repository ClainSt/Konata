import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/source_actions_provider.dart';
import '../../domain/models/media_source.dart';
import '../../domain/repositories/file_system_gateway.dart';
import '../theme/konata_palette.dart';
import '../widgets/design_system/konata_draggable_scrollbar.dart';
import '../widgets/design_system/konata_glass_dialog.dart';
import '../widgets/design_system/konata_pill_button.dart';
import '../widgets/design_system/konata_soft_text_field.dart';
import '../widgets/design_system/konata_surface_card.dart';
import 'source_selected_scope_panel.dart';

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
  final ScrollController _listScrollCtrl = ScrollController();
  final Set<String> _selectedPaths = <String>{};
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
        builder: (context, outerConstraints) {
          final targetH = outerConstraints.maxHeight.isFinite
              ? math.min(468.0, outerConstraints.maxHeight)
              : 468.0;
          return SizedBox(
            height: targetH,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildTopControls(p, filtered.length),
                const SizedBox(height: 10),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final listPane = KonataSurfaceCard(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: _buildEntryList(p, filtered),
                      );
                      final sidePane = SourceSelectedScopePanel(
                        selectedPaths: sortedSelected,
                        busy: _busy,
                        onRemovePath: _togglePath,
                        onClearAll: () =>
                            setState(() => _selectedPaths.clear()),
                        onShowHelp: () => showSourceBrowserHelpDialog(context),
                      );

                      if (constraints.maxWidth >= 560) {
                        return Row(
                          children: [
                            Expanded(flex: 3, child: listPane),
                            const SizedBox(width: 12),
                            SizedBox(
                              width: math.min(274.0, constraints.maxWidth * 0.42),
                              child: sidePane,
                            ),
                          ],
                        );
                      }
                      return Column(
                        children: [
                          Expanded(flex: 3, child: listPane),
                          const SizedBox(height: 10),
                          Expanded(flex: 2, child: sidePane),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildTopControls(KonataPalette p, int visibleCount) {
    final crumbs = _currentPath.isEmpty
        ? const <String>[]
        : _currentPath.split('/').where((s) => s.isNotEmpty).toList();
    final currentChecked =
        _currentPath.isNotEmpty && _selectedPaths.contains(_currentPath);

    return Column(
      children: [
        Row(
          children: [
            KonataPillButton.secondary(
              label: '上级',
              icon: Icons.arrow_upward_rounded,
              compact: true,
              onPressed: _loading || _currentPath.isEmpty ? null : _navigateUp,
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
                      Text('/', style: TextStyle(color: p.textMuted, fontSize: 12)),
                      _crumbButton(
                        p: p,
                        label: crumbs[i],
                        active: i == crumbs.length - 1,
                        onTap: _loading
                            ? null
                            : () => _loadDirectory(crumbs.sublist(0, i + 1).join('/')),
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
        KonataSoftTextField(
          controller: _searchController,
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
