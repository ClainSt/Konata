import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../providers.dart';
import 'source_selected_scope_panel.dart';

/// 媒体源目录范围选择弹窗，返回勾选后的相对路径列表；取消时返回 `null`。
///
/// 支持本地目录、WebDAV 与 SMB 逐级浏览，空勾选集合代表扫描媒体源全部根目录。
Future<List<String>?> showSourceFolderPickerDialog(
  BuildContext context, {
  String? sourceId,
  required MediaSourceKind kind,
  required String location,
  String? username,
  String? password,
  bool clearPassword = false,
  List<String> initialSelected = const <String>[],
}) {
  return showKonataGlassDialog<List<String>>(
    context: context,
    builder: (_) => _SourceFolderPickerDialog(
      sourceId: sourceId,
      kind: kind,
      location: location,
      username: username,
      password: password,
      clearPassword: clearPassword,
      initialSelected: initialSelected,
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
    required this.initialSelected,
  });

  final String? sourceId;
  final MediaSourceKind kind;
  final String location;
  final String? username;
  final String? password;
  final bool clearPassword;
  final List<String> initialSelected;

  @override
  ConsumerState<_SourceFolderPickerDialog> createState() =>
      _SourceFolderPickerDialogState();
}

class _SourceFolderPickerDialogState
    extends ConsumerState<_SourceFolderPickerDialog> {
  final Set<String> _selected = <String>{};
  String _currentPath = '';
  bool _loading = true;
  String? _errorText;
  List<RemoteEntry> _entries = const <RemoteEntry>[];

  @override
  void initState() {
    super.initState();
    for (final item in widget.initialSelected) {
      final clean = _normalizeRel(item);
      if (clean.isNotEmpty) {
        _selected.add(clean);
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _loadDirectory('');
      }
    });
  }

  String _normalizeRel(String raw) {
    return raw
        .trim()
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'^/+|/+$'), '');
  }

  Future<void> _loadDirectory(String relPath) async {
    final normalized = _normalizeRel(relPath);
    setState(() {
      _loading = true;
      _errorText = null;
      _currentPath = normalized;
    });
    try {
      final controller = ref.read(sourcesControllerProvider);
      final list = await controller.listDirectory(
        sourceId: widget.sourceId,
        kind: widget.kind,
        location: widget.location,
        username: widget.username,
        password: widget.password,
        clearPassword: widget.clearPassword,
        relativePath: normalized,
      );
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
        _errorText = DiagnosticTextSanitizer.redactSecrets('$error');
      });
    }
  }

  void _toggleSelected(String relPath) {
    final normalized = _normalizeRel(relPath);
    if (normalized.isEmpty) return;
    setState(() {
      if (!_selected.add(normalized)) {
        _selected.remove(normalized);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final screen = MediaQuery.sizeOf(context);
    final isWide = screen.width >= 680;
    final dialogHeight = (screen.height * 0.72).clamp(320.0, 560.0);
    final orderedSelected = _selected.toList(growable: false)..sort();

    return KonataGlassDialog(
      title: '选择扫库目录作用域',
      width: isWide ? 760 : (screen.width - 28).clamp(300.0, 520.0),
      actions: [
        KonataPillButton.ghost(
          label: '取消',
          onPressed: () => Navigator.of(context).pop(),
        ),
        KonataPillButton.primary(
          label: orderedSelected.isEmpty
              ? '使用全盘根目录'
              : '确认 (${orderedSelected.length})',
          onPressed: () => Navigator.of(context).pop(orderedSelected),
        ),
      ],
      child: SizedBox(
        height: dialogHeight,
        child: isWide
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    flex: 3,
                    child: _buildBrowserColumn(p),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    flex: 2,
                    child: SourceSelectedScopePanel(
                      selectedPaths: orderedSelected,
                      onRemovePath: (path) =>
                          setState(() => _selected.remove(path)),
                      onClearAll: () => setState(_selected.clear),
                    ),
                  ),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    flex: 3,
                    child: _buildBrowserColumn(p),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 132,
                    child: SourceSelectedScopePanel(
                      selectedPaths: orderedSelected,
                      onRemovePath: (path) =>
                          setState(() => _selected.remove(path)),
                      onClearAll: () => setState(_selected.clear),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildBrowserColumn(KonataPalette p) {
    final segments = _currentPath.isEmpty
        ? const <String>[]
        : _currentPath.split('/');

    return Container(
      decoration: BoxDecoration(
        color: p.elevatedSurface.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: p.hairline),
      ),
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              KonataCapsuleIconButton(
                icon: Icons.arrow_upward_rounded,
                tooltip: '返回上级目录',
                color: _currentPath.isEmpty ? p.textMuted : p.textPrimary,
                size: 16,
                padding: const EdgeInsets.all(6),
                onTap: _currentPath.isEmpty
                    ? () {}
                    : () {
                        final parent = segments.length <= 1
                            ? ''
                            : segments
                                .sublist(0, segments.length - 1)
                                .join('/');
                        _loadDirectory(parent);
                      },
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _currentPath.isEmpty ? '/' : '/$_currentPath',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                    color: p.textSecondary,
                  ),
                ),
              ),
              KonataCapsuleIconButton(
                icon: Icons.refresh_rounded,
                tooltip: '刷新当前目录',
                color: p.textSecondary,
                size: 16,
                padding: const EdgeInsets.all(6),
                onTap: () => _loadDirectory(_currentPath),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _buildDirectoryListBody(p),
          ),
        ],
      ),
    );
  }

  Widget _buildDirectoryListBody(KonataPalette p) {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2.2),
        ),
      );
    }
    if (_errorText != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.folder_off_outlined, size: 28, color: p.danger),
              const SizedBox(height: 8),
              Text(
                '目录加载失败：$_errorText',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, color: p.textSecondary),
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
    if (_entries.isEmpty) {
      return Center(
        child: Text(
          '当前目录下没有更多子文件夹',
          style: TextStyle(fontSize: 12.5, color: p.textMuted),
        ),
      );
    }

    return KonataDraggableScrollbar(
      builder: (context, scrollCtrl) => ListView.builder(
        controller: scrollCtrl,
        itemCount: _entries.length,
        itemBuilder: (context, index) {
          final entry = _entries[index];
          final rel = _normalizeRel(entry.relativePath);
          final checked = _selected.contains(rel);
          return Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => _loadDirectory(rel),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: checked
                      ? p.accent.withValues(alpha: 0.12)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Checkbox(
                      value: checked,
                      onChanged: (_) => _toggleSelected(rel),
                    ),
                    Icon(
                      Icons.folder_rounded,
                      size: 18,
                      color: checked ? p.accent : p.textSecondary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        entry.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: p.textPrimary,
                        ),
                      ),
                    ),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 18,
                      color: p.textMuted,
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
