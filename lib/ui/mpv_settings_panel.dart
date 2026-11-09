import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:android_file_picker/android_file_picker.dart';
import 'package:flutter/material.dart';

import '../core/mpv_config_store.dart';
import '../l10n/strings.dart';
import 'settings_panel.dart';

class MpvSettingsPanel extends StatefulWidget {
  const MpvSettingsPanel({super.key, this.store});
  final MpvConfigStore? store;

  @override
  State<MpvSettingsPanel> createState() => _MpvSettingsPanelState();
}

class _MpvSettingsPanelState extends State<MpvSettingsPanel> {
  late final MpvConfigStore store;
  bool busy = false;
  bool loaded = false;

  @override
  void initState() {
    super.initState();
    store = widget.store ?? MpvConfigStore.instance;
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      await store.initialize();
      if (mounted) {
        setState(() {
          loaded = true;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => loaded = true);
        _error(error);
      }
    }
  }

  void _error(Object e) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('${context.l10n.mpvError}: $e')));
    }
  }

  Future<bool> _run(Future<void> Function() action) async {
    if (busy) {
      return false;
    }
    setState(() => busy = true);
    try {
      await action();
      await _refresh();
      return true;
    } catch (e) {
      _error(e);
      return false;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _edit(String name) async {
    try {
      final current = await store.readConfig(name);
      if (!mounted) return;
      var edited = current;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(name),
          content: SizedBox(
            width: 650,
            height: MediaQuery.sizeOf(ctx).height * .48,
            child: TextFormField(
              key: ValueKey(name),
              initialValue: current,
              onChanged: (next) => edited = next,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              decoration: const InputDecoration(border: OutlineInputBorder()),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                final saved = await _run(() => store.restoreConfig(name));
                if (saved && ctx.mounted) Navigator.pop(ctx);
              },
              child: Text(context.l10n.mpvReset),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(MaterialLocalizations.of(ctx).cancelButtonLabel),
            ),
            FilledButton(
              onPressed: () async {
                final saved = await _run(() => store.saveConfig(name, edited));
                if (saved && ctx.mounted) Navigator.pop(ctx);
              },
              child: Text(context.l10n.mpvSave),
            ),
          ],
        ),
      );
    } catch (e) {
      _error(e);
    }
  }

  Future<Uint8List> _readLimited(PlatformFile file, int limit) async {
    final size = await file.length();
    if (size != null && size > limit) {
      throw const FormatException('File too large');
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in file.readAsByteStream()) {
      if (builder.length + chunk.length > limit) {
        throw const FormatException('File too large');
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  Future<void> _importConfig(String name) async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['conf', 'txt'],
    );
    if (file == null) return;
    await _run(() async {
      final bytes = await _readLimited(file, MpvConfigStore.maxConfigBytes);
      await store.saveConfig(name, utf8.decode(bytes));
    });
  }

  Future<void> _openDirectory() => _run(() async {
    final folder = await FilePicker.getDirectoryPath(
      dialogTitle: context.l10n.mpvOpenDirectory,
      androidOptions: const FilePickerAndroidOptions(
        safOptions: AndroidSAFOptions(grant: AndroidSAFGrant.lifetime),
      ),
    );
    if (folder == null) return;
    await store.selectFolder(folder);
    await store.setConfigEnabled(true);
  });

  Widget _fileTile(String name) => LayoutBuilder(
    builder: (context, constraints) {
      final actions = [
        TextButton(
          onPressed: busy ? null : () => _edit(name),
          child: Text(context.l10n.mpvEdit),
        ),
        TextButton(
          onPressed: busy ? null : () => _importConfig(name),
          child: Text(context.l10n.mpvImport),
        ),
      ];
      final tile = ListTile(
        key: ValueKey('mpv-file-$name'),
        leading: const Icon(Icons.description_outlined),
        title: Text(name),
        subtitle: Text(context.l10n.mpvNextPlayback),
        trailing: constraints.maxWidth < 540
            ? null
            : Wrap(spacing: 4, children: actions),
      );
      return SettingsPanel(
        child: constraints.maxWidth < 540
            ? Column(
                children: [
                  tile,
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 12, 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: actions,
                    ),
                  ),
                ],
              )
            : tile,
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    if (!loaded) return const Center(child: CircularProgressIndicator());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsPanel(
          child: SwitchListTile(
            key: const ValueKey('mpv-config-enabled'),
            title: Text(context.l10n.mpvEnable),
            subtitle: Text(context.l10n.mpvEnableDetail),
            value: store.enabled,
            onChanged: busy
                ? null
                : (v) => _run(() => store.setConfigEnabled(v)),
          ),
        ),
        const SizedBox(height: 12),
        if (store.externalFolder == null) ...[
          _fileTile('mpv.conf'),
          const SizedBox(height: 12),
          _fileTile('input.conf'),
          const SizedBox(height: 12),
        ],
        SettingsPanel(
          child: ListTile(
            key: const ValueKey('mpv-open-directory'),
            title: Text(context.l10n.mpvOpenDirectory),
            subtitle: store.externalFolder == null
                ? null
                : Text(
                    Platform.isAndroid
                        ? Uri.parse(store.externalFolder!).pathSegments.last
                        : store.externalFolder!,
                  ),
            leading: const Icon(Icons.folder_open),
            trailing: const Icon(Icons.chevron_right),
            onTap: busy ? null : _openDirectory,
          ),
        ),
        if (store.externalFolder != null)
          TextButton(
            onPressed: busy ? null : () => _run(() => store.selectFolder(null)),
            child: Text(context.l10n.mpvUseInternal),
          ),
      ],
    );
  }
}
