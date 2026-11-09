import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/artwork_settings.dart';
import '../core/image_store.dart';
import '../l10n/strings.dart';
import 'settings_panel.dart';

class ImageCacheSettings extends StatefulWidget {
  const ImageCacheSettings({super.key});
  @override
  State<ImageCacheSettings> createState() => _ImageCacheSettingsState();
}

class _ImageCacheSettingsState extends State<ImageCacheSettings>
    with WidgetsBindingObserver {
  int? _bytes;
  bool _failed = false, _scanning = false, _dirty = false, _opening = false;
  Timer? _debounce;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ImageStore.changed.addListener(_changed);
    _measure();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _changed();
  }

  void _changed() {
    _dirty = true;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _measure);
  }

  Future<void> _measure() async {
    if (_scanning || !mounted) return;
    _scanning = true;
    _dirty = false;
    try {
      final bytes = await ImageStore.diskBytes();
      if (mounted) {
        setState(() {
          _bytes = bytes;
          _failed = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      _scanning = false;
      if (_dirty && mounted) _changed();
    }
  }

  Future<void> _open() async {
    setState(() => _opening = true);
    try {
      final directory = await ImageStore.directory();
      await directory.create(recursive: true);
      if (Platform.isAndroid) {
        await const MethodChannel(
          'ccplayer/artwork',
        ).invokeMethod<void>('openDirectory');
      } else if (Platform.isWindows) {
        await Process.start('explorer.exe', [directory.path]);
      } else {
        await Process.start(Platform.isMacOS ? 'open' : 'xdg-open', [
          directory.path,
        ]);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.cacheDirectoryUnavailable)),
        );
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    ImageStore.changed.removeListener(_changed);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  static String size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(2)} KiB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MiB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GiB';
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      SettingsPanel(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.l10n.imageCache,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _failed
                          ? context.l10n.cacheSizeUnavailable
                          : _bytes == null
                          ? context.l10n.measuringCache
                          : size(_bytes!),
                      key: const ValueKey('image-cache-bytes'),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: TextButton(
                    key: const ValueKey('open-image-cache'),
                    onPressed: _opening ? null : _open,
                    child: Text(
                      context.l10n.openCacheDirectory,
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),
      SettingsPanel(
        child: ListenableBuilder(
          listenable: ArtworkSettings.instance,
          builder: (context, _) => SwitchListTile(
            key: const ValueKey('detail-backdrop-switch'),
            title: Text(context.l10n.detailBackdrop),
            value: ArtworkSettings.instance.backdrop,
            onChanged: (value) async {
              try {
                await ArtworkSettings.instance.setBackdrop(value);
              } catch (_) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(context.l10n.cacheSettingFailed)),
                  );
                }
              }
            },
          ),
        ),
      ),
    ],
  );
}
