import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../core/catalog.dart';
import '../core/sources.dart';
import '../core/selected_scanner.dart';

class BrowserEntry {
  const BrowserEntry(this.name, this.relative, this.directory, this.size);
  final String name, relative;
  final bool directory;
  final int? size;
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
  @override
  void initState() {
    super.initState();
    _load();
  }

  String get sourceId => widget.source['id'].toString();
  bool get local => widget.source['kind'] == 'local';
  String get displayPath => current.isEmpty ? '/' : '/$current/';
  Future<void> _load([String? path]) async {
    final target = path ?? current;
    final generation = ++_generation;
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

  Future<void> _select(String path, String mode) async {
    try {
      await Catalog.instance.addScanRoot(sourceId, path, mode);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '已选：${path.isEmpty ? "/" : path}（${mode == "work" ? "单部作品" : "作品合集"}）',
            ),
          ),
        );
      }
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
      final count = await SelectedScanner.scan(widget.source);
      _notice('已扫描 $count 个视频，可返回海报墙查看作品');
    } catch (e) {
      _notice('扫描失败：$e');
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
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: '刷新当前目录',
                onPressed: loading ? null : () => _load(),
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
                    itemCount: entries.length + (current.isEmpty ? 0 : 1),
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
                      final item = entries[index - (current.isEmpty ? 0 : 1)];
                      return ListTile(
                        leading: Icon(
                          item.directory
                              ? Icons.folder_rounded
                              : Catalog.isVideo(item.name)
                              ? Icons.movie_outlined
                              : Catalog.isSubtitle(item.name)
                              ? Icons.subtitles_outlined
                              : Icons.insert_drive_file_outlined,
                          color: item.directory
                              ? const Color(0xff8dbafa)
                              : null,
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
                        trailing: item.directory
                            ? PopupMenuButton<String>(
                                tooltip: '选取此文件夹刮削',
                                onSelected: (mode) =>
                                    _select(item.relative, mode),
                                itemBuilder: (_) => const [
                                  PopupMenuItem(
                                    value: 'work',
                                    child: Text('设为单部作品'),
                                  ),
                                  PopupMenuItem(
                                    value: 'collection',
                                    child: Text('设为作品合集'),
                                  ),
                                ],
                              )
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
                            '单部作品：例如 动画-单作品/86 (2021) {tmdb-100565}。\n'
                            '作品合集：例如 动画-单作品，合集下的每个直属子文件夹视为一部作品。\n'
                            '点击文件夹进入目录，或点击右侧菜单直接选取。只扫描已选范围，不修改任何媒体文件。',
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
                            '${root['relative_path'].toString().isEmpty ? "/" : root['relative_path']} · ${root['mode'] == 'work' ? "作品" : "合集"}',
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
                    OutlinedButton.icon(
                      icon: const Icon(Icons.movie_outlined),
                      label: const Text('此目录是单部作品'),
                      onPressed: loading || (!local && current.isEmpty)
                          ? null
                          : () => _select(current, 'work'),
                    ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.collections_bookmark_outlined),
                      label: const Text('此目录是作品合集'),
                      onPressed: loading
                          ? null
                          : () => _select(current, 'collection'),
                    ),
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
