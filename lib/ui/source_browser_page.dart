import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../core/catalog.dart';
import '../core/sources.dart';
import '../core/selected_scan_workflow.dart';
import '../core/scan_activity.dart';
import 'scan_progress_dialog.dart';

class BrowserEntry {
  const BrowserEntry(this.name, this.relative, this.directory, this.size);
  final String name, relative;
  final bool directory;
  final int? size;
}

/// Fast, in-memory filtering of the current folder's 1,000+ children.
abstract final class SourceBrowserSearch {
  static List<BrowserEntry> filter(List<BrowserEntry> entries, String query) {
    final term = query.trim().toLowerCase();
    if (term.isEmpty) return entries;
    return entries.where((e) => e.name.toLowerCase().contains(term)).toList();
  }
}

class SourceBrowserPage extends StatefulWidget {
  const SourceBrowserPage({super.key, required this.source});
  final Map<String, Object?> source;
  @override
  State<SourceBrowserPage> createState() => _SourceBrowserPageState();
}

class _SourceBrowserPageState extends State<SourceBrowserPage> {
  String current = '';
  List<BrowserEntry> entries = [];
  bool loading = false, scanning = false;
  String? error;
  int _generation = 0;
  final TextEditingController _searchController = TextEditingController();
  String searchTerm = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _startBrowsing();
  }

  Future<void> _startBrowsing() async {
    // Folder checkboxes are a temporary scan selection, not persisted media config.
    await Catalog.instance.clearScanRoots(sourceId);
    if (mounted) await _load();
  }

  String get sourceId => widget.source['id'].toString();
  bool get local => widget.source['kind'] == 'local';
  String get displayPath => current.isEmpty ? '/' : '/$current/';
  Future<void> _load([String? path]) async {
    final target = path ?? current;
    final generation = ++_generation;
    if (target != current) {
      _searchController.clear();
      searchTerm = '';
    }
    setState(() {
      current = target;
      loading = true;
      error = null;
      entries = [];
    });
    try {
      List<BrowserEntry> list;
      if (local) {
        final root = widget.source['location'].toString();
        final dir = Directory(
          target.isEmpty ? root : p.joinAll([root, ...target.split('/')]),
        );
        final children = await dir.list(followLinks: false).toList();
        list = children.map((entity) {
          final relative = target.isEmpty
              ? p.basename(entity.path)
              : '$target/${p.basename(entity.path)}';
          final isFolder = entity is Directory;
          return BrowserEntry(
            p.basename(entity.path),
            relative,
            isFolder,
            null,
          );
        }).toList();
      } else {
        final source = await Catalog.instance.withCredentials(widget.source);
        final dav = WebDav(source);
        final result = await dav.list(dav.directoryUri(target));
        list = result.map((entry) {
          final relative = target.isEmpty
              ? entry.name
              : '$target/${entry.name}';
          return BrowserEntry(
            entry.name,
            relative,
            entry.isDirectory,
            entry.size,
          );
        }).toList();
      }
      list.sort((a, b) {
        if (a.directory != b.directory) return a.directory ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      if (mounted && generation == _generation) {
        setState(() {
          entries = list;
          loading = false;
        });
      }
    } catch (e) {
      if (mounted && generation == _generation) {
        setState(() {
          error = e.toString();
          loading = false;
        });
      }
    }
  }

  void _up() {
    if (current.isEmpty) return;
    final segments = current.split('/');
    segments.removeLast();
    _load(segments.join('/'));
  }

  Future<void> _toggle(String path) async {
    try {
      await Catalog.instance.toggleScanRoot(sourceId, path);
    } catch (e) {
      _notice(e.toString());
    }
  }

  void _notice(String message) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _scan() async {
    if (scanning || Catalog.instance.scanning) return;
    setState(() => scanning = true);
    try {
      // Successful indexing immediately starts TMDB/Bangumi metadata scraping.
      // All progress and errors are reported in the top-right inspector.
      await SelectedScanWorkflow.run(widget.source);
    } catch (_) {
      // The workflow already records the error in the progress inspector.
      // No bottom snackbar is shown during or after a scan.
    } finally {
      if (mounted) setState(() => scanning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final catalog = Catalog.instance;
    return AnimatedBuilder(
      animation: catalog,
      builder: (context, _) {
        final selected = catalog.rootsFor(sourceId);
        final shownEntries = SourceBrowserSearch.filter(entries, searchTerm);
        final breadcrumbs = <({String label, String path})>[
          (label: widget.source['label'].toString(), path: ''),
        ];
        var buffer = '';
        if (current.isNotEmpty) {
          for (final section in current.split('/')) {
            buffer = buffer.isEmpty ? section : '$buffer/$section';
            breadcrumbs.add((label: section, path: buffer));
          }
        }
        return Scaffold(
          appBar: AppBar(
            title: Text('浏览目录 · ${widget.source['label']}'),
            actions: [
              AnimatedBuilder(
                animation: ScanActivityStore.instance,
                builder: (ctx, _) {
                  final activity = ScanActivityStore.instance.forSource(
                    sourceId,
                  );
                  final active =
                      activity?.phase == ScanPhase.scanning ||
                      activity?.phase == ScanPhase.scraping;
                  return IconButton(
                    key: const ValueKey('scan-progress-button'),
                    tooltip: '扫描进度',
                    icon: active
                        ? const SizedBox(
                            width: 23,
                            height: 23,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.fact_check_outlined),
                    onPressed: () =>
                        ScanProgressDialog.show(context, sourceId: sourceId),
                  );
                },
              ),
            ],
          ),
          body: Column(
            children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Row(
                  children: [
                    for (final crumb in breadcrumbs) ...[
                      TextButton(
                        onPressed: loading ? null : () => _load(crumb.path),
                        child: Text(crumb.label),
                      ),
                      const Icon(Icons.chevron_right, size: 17),
                    ],
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 5,
                ),
                child: Row(
                  children: [
                    Checkbox(
                      value: selected.any((r) => r['relative_path'] == current),
                      onChanged: loading ? null : (_) => _toggle(current),
                    ),
                    const Icon(Icons.folder_open, size: 19),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        displayPath,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      '${entries.length} 项',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 8, 18, 6),
                child: TextField(
                  key: const ValueKey('folder-search-field'),
                  controller: _searchController,
                  onChanged: (value) => setState(() => searchTerm = value),
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    hintText: '搜索当前文件夹（名称 / TMDB ID）',
                    border: const OutlineInputBorder(),
                    isDense: true,
                    suffixIcon: searchTerm.isEmpty
                        ? null
                        : IconButton(
                            key: const ValueKey('clear-folder-search'),
                            tooltip: '清除搜索',
                            icon: const Icon(Icons.close),
                            onPressed: () {
                              _searchController.clear();
                              setState(() => searchTerm = '');
                            },
                          ),
                  ),
                ),
              ),
              if (searchTerm.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 3,
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '匹配 ${shownEntries.length} / ${entries.length} 项',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
                ),
              if (loading) const LinearProgressIndicator(),
              if (error != null)
                Expanded(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.cloud_off_outlined, size: 42),
                          const SizedBox(height: 12),
                          Text('目录读取失败：$error', textAlign: TextAlign.center),
                          const SizedBox(height: 12),
                          FilledButton.icon(
                            onPressed: () => _load(),
                            icon: const Icon(Icons.refresh),
                            label: const Text('重试'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              if (error == null)
                Expanded(
                  child: ListView.builder(
                    itemCount: shownEntries.length + (current.isEmpty ? 0 : 1),
                    itemBuilder: (context, index) {
                      if (current.isNotEmpty && index == 0) {
                        return ListTile(
                          leading: const Icon(
                            Icons.drive_folder_upload_outlined,
                          ),
                          title: const Text('.. 返回上级'),
                          onTap: _up,
                        );
                      }
                      final item =
                          shownEntries[index - (current.isEmpty ? 0 : 1)];
                      return ListTile(
                        leading: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (item.directory)
                              Checkbox(
                                value: selected.any(
                                  (r) => r['relative_path'] == item.relative,
                                ),
                                onChanged: loading
                                    ? null
                                    : (_) => _toggle(item.relative),
                              ),
                            Icon(
                              item.directory
                                  ? Icons.folder_rounded
                                  : Catalog.isVideo(item.name)
                                  ? Icons.movie_outlined
                                  : Catalog.isSubtitle(item.name)
                                  ? Icons.subtitles_outlined
                                  : Icons.insert_drive_file_outlined,
                              color: item.directory
                                  ? Theme.of(context).colorScheme.primary
                                  : null,
                            ),
                          ],
                        ),
                        title: Text(
                          item.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: item.directory
                            ? null
                            : Text(
                                item.size == null
                                    ? '文件'
                                    : '${(item.size! / 1048576).toStringAsFixed(1)} MB',
                              ),
                        onTap: item.directory
                            ? () => _load(item.relative)
                            : null,
                      );
                    },
                  ),
                ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 5,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '已选刮削范围（${selected.length}）',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    IconButton(
                      tooltip: '帮助',
                      icon: const Icon(Icons.help_outline),
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('怎样选择刮削文件夹？'),
                          content: const Text(
                            '勾选文件夹即可加入刮削范围。既能勾选单部作品，也能勾选包含多部作品的上级目录。软件扫描后自动判断作品归属，对不确定的作品标记待复核。点击文件夹名称仍然可以进入子目录。',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx),
                              child: const Text('知道了'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 112),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 0,
                    children: [
                      for (final root in selected)
                        InputChip(
                          label: Text(
                            root['relative_path'].toString().isEmpty
                                ? '/'
                                : root['relative_path'].toString(),
                            overflow: TextOverflow.ellipsis,
                          ),
                          onDeleted: () => catalog.removeScanRoot(
                            sourceId,
                            root['relative_path'].toString(),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 14),
                child: Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    FilledButton.icon(
                      icon: scanning
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.travel_explore),
                      label: Text('扫描已选目录（${selected.length}）'),
                      onPressed:
                          scanning || catalog.scanning || selected.isEmpty
                          ? null
                          : _scan,
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
