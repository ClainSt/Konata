import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../providers.dart';
import '../state/sources_controller.dart';
import 'source_selected_scope_panel.dart';

enum _FolderPickerViewMode { browse, selectedManage }

/// 媒体源目录浏览、搜索与多选范围毛玻璃弹窗（支持本地 / WebDAV / SMB 统一浏览）。
///
Future<void> showSourceFolderPickerDialog(
  BuildContext context, {
  String? sourceId,
  required MediaSourceKind kind,
  required String location,
  String? username,
  String? password,
  bool clearPassword = false,
  String? sourceLabel,
  required Future<void> Function(List<String> selectedPaths) onScanSelected,
}) {
  return showKonataGlassDialog<void>(
    context: context,
    builder: (_) => _SourceFolderPickerDialog(
      sourceId: sourceId,
      kind: kind,
      location: location,
      username: username,
      password: password,
      clearPassword: clearPassword,
      sourceLabel: sourceLabel,
      onScanSelected: onScanSelected,
    ),
  );
}

class _SourceFolderPickerDialog extends ConsumerStatefulWidget {
  const _SourceFolderPickerDialog({
    required this.sourceId,
    required this.kind,
    required this.location,
    required this.username,
    required this.password,
    required this.clearPassword,
    this.sourceLabel,
    required this.onScanSelected,
  });

  final String? sourceId;
  final MediaSourceKind kind;
  final String location;
  final String? username;
  final String? password;
  final bool clearPassword;
  final String? sourceLabel;
  final Future<void> Function(List<String> selectedPaths) onScanSelected;

  @override
  ConsumerState<_SourceFolderPickerDialog> createState() =>
      _SourceFolderPickerDialogState();
}

class _SourceFolderPickerDialogState
    extends ConsumerState<_SourceFolderPickerDialog> {
  static final RegExp _edgeSlashes = RegExp(r'^/+|/+$');

  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  final ScrollController _listScrollCtrl = ScrollController();
  final Set<String> _selectedPaths = <String>{};

  _FolderPickerViewMode _viewMode = _FolderPickerViewMode.browse;
  String _currentPath = '';
  String _searchQuery = '';
  List<RemoteEntry> _entries = const <RemoteEntry>[];
  SourceDirectoryBrowseSession? _cloudBrowse;
  bool _loading = true;
  bool _busy = false;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _loadDirectory('');
      }
    });
  }

  @override
  void dispose() {
    unawaited(_cloudBrowse?.close());
    _listScrollCtrl.dispose();
    _searchFocusNode.dispose();
    _searchController.dispose();
    super.dispose();
  }

  String _normalizeRel(String raw) {
    return raw.trim().replaceAll('\\', '/').replaceAll(_edgeSlashes, '');
  }

  Future<void> _loadDirectory(String relPath, {bool refresh = false}) async {
    final normalized = _normalizeRel(relPath);
    setState(() {
      _loading = true;
      _errorText = null;
      _currentPath = normalized;
      _searchQuery = '';
      _searchController.clear();
    });
    try {
      final controller = ref.read(sourcesControllerProvider);
      final List<RemoteEntry> list;
      if (widget.kind == MediaSourceKind.cloudDrive) {
        if (refresh) {
          final previous = _cloudBrowse;
          _cloudBrowse = null;
          await previous?.close();
        }
        var session = _cloudBrowse;
        if (session == null) {
          session = await controller.openDirectoryBrowseSession(
            sourceId: widget.sourceId,
            kind: widget.kind,
            location: widget.location,
          );
          if (!mounted) {
            await session.close();
            return;
          }
          _cloudBrowse = session;
        }
        list = await session.listDirectory(normalized, includeFiles: true);
      } else {
        list = await controller.listDirectory(
          sourceId: widget.sourceId,
          kind: widget.kind,
          location: widget.location,
          username: widget.username,
          password: widget.password,
          clearPassword: widget.clearPassword,
          relativePath: normalized,
          includeFiles: true,
        );
      }
      if (!mounted) return;
      setState(() {
        _entries = list;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _entries = const <RemoteEntry>[];
        _loading = false;
        _errorText =
            '读取目录失败: ${DiagnosticTextSanitizer.redactSecrets('$error')}';
      });
    }
  }

  void _navigateUp() {
    if (_currentPath.isEmpty) return;
    final parts = _currentPath.split('/')..removeLast();
    _loadDirectory(parts.join('/'));
  }

  void _togglePath(String relativePath) {
    final norm = _normalizeRel(relativePath);
    if (norm.isEmpty) return;
    setState(() {
      if (!_selectedPaths.remove(norm)) {
        _selectedPaths.add(norm);
      }
    });
  }

  List<String> get _currentRootDirectoryPaths {
    return _entries
        .where((e) => e.isDirectory)
        .map((e) => _normalizeRel(e.relativePath))
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
  }

  void _toggleAllRootDirectories() {
    final rootDirs = _currentRootDirectoryPaths;
    if (rootDirs.isEmpty) return;
    final allSelected = rootDirs.every(_selectedPaths.contains);
    setState(() {
      if (allSelected) {
        _selectedPaths.removeAll(rootDirs);
      } else {
        _selectedPaths.addAll(rootDirs);
      }
    });
  }

  void _handleRootCrumbTap() {
    if (_loading) return;
    if (_currentPath.isNotEmpty) {
      _loadDirectory('');
      return;
    }
    if (_currentRootDirectoryPaths.isNotEmpty) {
      _toggleAllRootDirectories();
    } else {
      _loadDirectory('');
    }
  }

  void _removePathsBatch(List<String> paths) {
    if (paths.isEmpty) return;
    setState(() {
      for (final raw in paths) {
        _selectedPaths.remove(_normalizeRel(raw));
      }
    });
  }

  List<String> get _sortedSelected {
    final list = _selectedPaths.toList()
      ..sort(SourcesController.compareNaturalFolderName);
    return list;
  }

  Future<void> _scanNow() async {
    final callback = widget.onScanSelected;
    if (_selectedPaths.isEmpty || _busy) return;
    setState(() => _busy = true);
    final targets = _sortedSelected;
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

  Widget _buildSearchField(KonataPalette p) {
    return KonataSearchField(
      controller: _searchController,
      focusNode: _searchFocusNode,
      dense: true,
      onClear: () {
        _searchController.clear();
        setState(() => _searchQuery = '');
      },
      onChanged: (v) => setState(() => _searchQuery = v),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final screen = MediaQuery.sizeOf(context);
    final isPhoneLandscape =
        screen.shortestSide < KonataAdaptiveTokens.tabletBreakpoint &&
        screen.width > screen.height;
    final sortedSelected = _sortedSelected;
    final filtered = _filteredEntries;
    final title =
        (widget.sourceLabel != null && widget.sourceLabel!.trim().isNotEmpty)
        ? widget.sourceLabel!.trim()
        : widget.kind == MediaSourceKind.cloudDrive
        ? '光鸭云盘 · 选择目录'
        : '选择扫库目录作用域';

    return KonataGlassDialog(
      width: 940,
      maxHeight: 640,
      title: title,
      inlineHeaderTrailing: isPhoneLandscape,
      headerBottomSpacing: isPhoneLandscape ? 4 : null,
      headerTrailing: isPhoneLandscape
          ? SizedBox(
              width: math.min(240.0, screen.width * 0.36),
              child: _buildSearchField(p),
            )
          : null,
      onClose: _busy ? () {} : () => Navigator.of(context).pop(),
      actions: [
        KonataPillButton.ghost(
          label: '取消',
          compact: true,
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
        ),
        KonataTooltip(
          message: sortedSelected.isEmpty ? '需要选择扫描目录' : '扫描',
          child: KonataPillButton.primary(
            key: const ValueKey('source_start_scan'),
            label: '扫描',
            compact: true,
            onPressed: _busy || sortedSelected.isEmpty ? null : _scanNow,
          ),
        ),
      ],
      child: LayoutBuilder(
        builder: (dialogCtx, outerConstraints) {
          final targetH = outerConstraints.maxHeight.isFinite
              ? math.min(488.0, outerConstraints.maxHeight)
              : 488.0;
          final landscapeCompact =
              KonataGlassDialog.isLandscapeCompactInputActive(dialogCtx);

          if (isPhoneLandscape) {
            return SizedBox(
              height: targetH,
              child: Offstage(
                offstage: landscapeCompact,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      flex: 58,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _buildPathNavigationRow(p, filtered.length),
                          const SizedBox(height: 6),
                          Expanded(
                            child: KonataSurfaceCard(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: _buildEntryList(p, filtered),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 42,
                      child: SourceSelectedScopePanel(
                        selectedPaths: sortedSelected,
                        busy: _busy,
                        showBackButton: false,
                        onBackToBrowse: () {},
                        onRemovePathsBatch: _removePathsBatch,
                        onShowHelp: () =>
                            showSourceBrowserHelpDialog(dialogCtx),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }

          return SizedBox(
            height: targetH,
            child: _viewMode == _FolderPickerViewMode.selectedManage
                ? SourceSelectedScopePanel(
                    selectedPaths: sortedSelected,
                    busy: _busy,
                    onBackToBrowse: () => setState(
                      () => _viewMode = _FolderPickerViewMode.browse,
                    ),
                    onRemovePathsBatch: _removePathsBatch,
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

  Widget _buildSelectedEntryBar(KonataPalette p, {required int selectedCount}) {
    final minH = KonataAdaptiveTokens.isAndroid
        ? KonataAdaptiveTokens.touchTarget
        : 40.0;
    return MouseRegion(
      cursor: _busy ? SystemMouseCursors.basic : SystemMouseCursors.click,
      child: GestureDetector(
        key: const ValueKey('source_selected_scope_entry'),
        behavior: HitTestBehavior.opaque,
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
            borderRadius: KonataTheme.borderRadiusCard,
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
                  '已选目录 · $selectedCount（点击管理）',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: p.textPrimary,
                    fontSize: KonataTheme.fontSizeBodySm,
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              KonataCapsuleIconButton(
                icon: Icons.help_outline_rounded,
                tooltip: '多选扫描说明',
                color: p.textSecondary,
                size: 17,
                fixedSize: KonataAdaptiveTokens.isAndroid
                    ? KonataAdaptiveTokens.touchTarget
                    : 30.0,
                padding: const EdgeInsets.all(4),
                onTap: () => showSourceBrowserHelpDialog(context),
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

  Widget _buildPathNavigationRow(KonataPalette p, int visibleCount) {
    final crumbs = _currentPath.isEmpty
        ? const <String>[]
        : _currentPath.split('/').where((s) => s.isNotEmpty).toList();
    final rootDirPaths = _currentRootDirectoryPaths;
    final bool? checkboxValue;
    if (_currentPath.isNotEmpty) {
      checkboxValue = _selectedPaths.contains(_currentPath);
    } else if (rootDirPaths.isEmpty) {
      checkboxValue = false;
    } else {
      final selectedInRoot = rootDirPaths.where(_selectedPaths.contains).length;
      if (selectedInRoot == 0) {
        checkboxValue = false;
      } else if (selectedInRoot == rootDirPaths.length) {
        checkboxValue = true;
      } else {
        checkboxValue = null;
      }
    }

    return Row(
      children: [
        KonataPillButton.secondary(
          label: '上级',
          icon: Icons.arrow_upward_rounded,
          compact: true,
          onPressed: _loading || _currentPath.isEmpty ? null : _navigateUp,
        ),
        const SizedBox(width: 6),
        KonataTooltip(
          message: _currentPath.isEmpty ? '全选或取消全选根路径下的全部目录' : '勾选或取消勾选当前目录',
          child: Checkbox(
            tristate: _currentPath.isEmpty,
            value: checkboxValue,
            onChanged: _loading
                ? null
                : (_currentPath.isEmpty
                      ? (rootDirPaths.isEmpty
                            ? null
                            : (_) => _toggleAllRootDirectories())
                      : (_) => _togglePath(_currentPath)),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _crumbButton(
                  key: const ValueKey('source_picker_root_crumb'),
                  p: p,
                  label: '根目录',
                  active: _currentPath.isEmpty,
                  onTap: _loading ? null : _handleRootCrumbTap,
                ),
                for (var i = 0; i < crumbs.length; i++) ...[
                  Text(
                    '/',
                    style: TextStyle(
                      color: p.textMuted,
                      fontSize: KonataTheme.fontSizeCaption,
                    ),
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
        const SizedBox(width: 6),
        KonataCapsuleIconButton(
          icon: Icons.refresh_rounded,
          tooltip: '刷新当前目录',
          color: p.textSecondary,
          size: 16,
          fixedSize: KonataAdaptiveTokens.isAndroid
              ? KonataAdaptiveTokens.touchTarget
              : 30.0,
          padding: const EdgeInsets.all(4),
          onTap: _loading
              ? null
              : () => _loadDirectory(_currentPath, refresh: true),
        ),
        const SizedBox(width: 6),
        Text(
          _searchQuery.isEmpty
              ? '${_entries.length} 项'
              : '匹配 $visibleCount / ${_entries.length}',
          style: TextStyle(
            color: p.textSecondary,
            fontSize: KonataTheme.fontSizeCaption,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }

  Widget _buildTopControls(
    KonataPalette p,
    int visibleCount, {
    bool landscapeCompact = false,
  }) {
    return Column(
      children: [
        Offstage(
          offstage: landscapeCompact,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildPathNavigationRow(p, visibleCount),
              const SizedBox(height: 8),
            ],
          ),
        ),
        _buildSearchField(p),
      ],
    );
  }

  Widget _crumbButton({
    Key? key,
    required KonataPalette p,
    required String label,
    required bool active,
    required VoidCallback? onTap,
  }) {
    return MouseRegion(
      cursor: onTap != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      child: GestureDetector(
        key: key,
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Text(
            label,
            style: TextStyle(
              color: active ? p.textPrimary : p.textSecondary,
              fontSize: KonataTheme.fontSizeBodyXs,
              fontWeight: active ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEntryList(KonataPalette p, List<RemoteEntry> entries) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_errorText != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _errorText!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: p.danger,
                  fontSize: KonataTheme.fontSizeBodySm,
                ),
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
          style: TextStyle(
            color: p.textSecondary,
            fontSize: KonataTheme.fontSizeBodySm,
          ),
        ),
      );
    }

    // 列表视口独立重绘边界与局部透明材质，严格裁切滚动边缘与悬停响应，不触发外层毛玻璃重绘。
    return RepaintBoundary(
      child: ClipRect(
        child: Material(
          type: MaterialType.transparency,
          child: KonataDraggableScrollbar(
            controller: _listScrollCtrl,
            builder: (_, ctrl) => ListView.separated(
              controller: ctrl,
              padding: const EdgeInsets.only(right: 12),
              itemCount: entries.length,
              separatorBuilder: (_, _) => Divider(
                height: 1,
                color: p.hairline,
                indent: 14,
                endIndent: 14,
              ),
              itemBuilder: (_, index) {
                final entry = entries[index];
                final rel = _normalizeRel(entry.relativePath);
                return SourceBrowserEntryRow(
                  entry: entry,
                  checked: entry.isDirectory && _selectedPaths.contains(rel),
                  onEnterDirectory: () => _loadDirectory(rel),
                  onToggleDirectory: () => _togglePath(rel),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
