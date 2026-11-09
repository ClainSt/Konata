import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../core/bangumi_offline_index.dart';
import '../l10n/strings.dart';
import 'settings_navigation.dart';

/// Delete only this picker-owned copy, never the user's selected original or
/// other ongoing file-picker operations. Android caches each pick separately.
Future<void> cleanOfflinePickerCopy(File selected, Directory temporary) async {
  final picker = Directory(p.join(temporary.path, 'file_picker'));
  if (!await picker.exists() || !await selected.exists()) return;
  final root = await picker.resolveSymbolicLinks();
  final path = await selected.resolveSymbolicLinks();
  if (!p.isWithin(root, path)) return;
  final parts = p.split(p.relative(path, from: root));
  if (parts.length != 2 || !RegExp(r'^\d+$').hasMatch(parts.first)) return;
  await File(path).delete();
  final parent = Directory(p.dirname(path));
  if (await parent.list().isEmpty) await parent.delete();
}

class BangumiOfflineSettings extends StatefulWidget {
  const BangumiOfflineSettings({super.key, this.index});
  final BangumiOfflineIndex? index;
  @override
  State<BangumiOfflineSettings> createState() => _BangumiOfflineSettingsState();
}

class _BangumiOfflineSettingsState extends State<BangumiOfflineSettings> {
  String size(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
  BangumiOfflineIndex? index;
  Map<String, Object?>? current;
  OfflineSnapshot? latest;
  bool busy = false, failed = false;
  String phase = '';
  double? fraction;
  DateTime lastProgress = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    index =
        widget.index ??
        (BangumiOfflineIndex.directory == null
            ? null
            : BangumiOfflineIndex(BangumiOfflineIndex.directory!));
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final status = await index?.status();
      if (mounted) setState(() => current = status);
    } catch (_) {
      if (mounted) setState(() => failed = true);
    }
  }

  @override
  void dispose() {
    index?.cancel();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (busy || index == null) return;
    setState(() {
      busy = true;
      failed = false;
      phase = '';
      fraction = null;
    });
    try {
      await action();
    } on OfflineIndexCancelled {
      if (mounted) setState(() => phase = '');
    } catch (_) {
      if (mounted) setState(() => failed = true);
    } finally {
      await _refresh();
      if (mounted) setState(() => busy = false);
    }
  }

  void _progress(String value, int done, int total) {
    if (!mounted) return;
    final now = DateTime.now();
    if (phase == value &&
        done != total &&
        now.difference(lastProgress).inMilliseconds < 200) {
      return;
    }
    lastProgress = now;
    setState(() {
      phase = value;
      fraction = total > 0 ? done / total : null;
    });
  }

  Future<void> _import() => _run(() async {
    final selected = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['zip'],
    );
    if (selected == null) return;
    if (selected.path == null) {
      throw const FileSystemException('No readable archive');
    }
    final source = File(selected.path!);
    try {
      if (!mounted) return;
      await index!.install(zip: source, progress: _progress);
    } finally {
      if (Platform.isAndroid) {
        await cleanOfflinePickerCopy(source, await getTemporaryDirectory());
      }
    }
  });

  @override
  Widget build(BuildContext context) {
    final strings = context.l10n;
    final upToDate =
        latest != null && current?['archive_sha256'] == latest!.digest;
    final message = switch (phase) {
      'download' => strings.offlineDownloading,
      'import' => strings.offlineImporting,
      'index' => strings.offlineIndexing,
      'complete' => strings.offlineReady,
      _ => '',
    };
    return SettingsSurface(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 720),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      strings.offlineBangumi,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).closeButtonTooltip,
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(strings.offlineBangumiHint),
                    const SizedBox(height: 16),
                    Text(
                      current == null
                          ? strings.offlineNotInstalled
                          : strings.offlineInstalled,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if (current != null) ...[
                      Text('${current!['version']}'),
                      Text('${strings.offlineCount}: ${current!['subjects']}'),
                      Text(
                        '${strings.offlineIndexSize}: ${size(current!['bytes'] as int)}',
                      ),
                    ],
                    const SizedBox(height: 16),
                    Text(strings.offlineUpdateHelp),
                    const SizedBox(height: 8),
                    Text(strings.offlineSnapshotHelp),
                    if (latest != null) ...[
                      const SizedBox(height: 16),
                      Text(
                        upToDate
                            ? strings.offlineUpToDate
                            : strings.offlineAvailable,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text('${latest!.version}\n${size(latest!.bytes)}'),
                    ],
                    if (busy) ...[
                      const SizedBox(height: 16),
                      LinearProgressIndicator(value: fraction),
                    ],
                    if (message.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(message),
                      ),
                    if (failed)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          strings.offlineFailed,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    const SizedBox(height: 20),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton(
                          onPressed: busy || index == null
                              ? null
                              : () => _run(() async {
                                  final snapshot = await index!.checkLatest();
                                  if (mounted) {
                                    setState(() => latest = snapshot);
                                  }
                                }),
                          child: Text(strings.offlineCheck),
                        ),
                        FilledButton(
                          onPressed: busy || latest == null || upToDate
                              ? null
                              : () => _run(
                                  () => index!.install(
                                    snapshot: latest,
                                    progress: _progress,
                                  ),
                                ),
                          child: Text(strings.offlineDownload),
                        ),
                        OutlinedButton(
                          onPressed: busy || index == null ? null : _import,
                          child: Text(strings.offlineImport),
                        ),
                        if (busy)
                          TextButton(
                            onPressed: () => index?.cancel(),
                            child: Text(strings.cancel),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        TextButton(
                          onPressed: busy
                              ? null
                              : () => launchUrl(
                                  Uri.parse(
                                    'https://github.com/bangumi/Archive/releases',
                                  ),
                                  mode: LaunchMode.externalApplication,
                                ),
                          child: Text(strings.offlineOfficialSite),
                        ),
                        TextButton(
                          onPressed: busy || index == null
                              ? null
                              : () => _run(() => index!.remove()),
                          child: Text(strings.offlineRemove),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
