import 'settings_panel.dart';
import 'extensions_panel.dart';
import 'optional_scraping_settings.dart';
import 'image_cache_settings.dart';
import '../core/optional_features.dart';
import 'mpv_settings_panel.dart';
import '../core/catalog.dart';
import '../core/image_store.dart';
import '../core/artwork_settings.dart';
import '../core/library_backup_exporter.dart';
import '../core/library_backup_restorer.dart';
import '../core/app_language.dart';
import '../core/watch_settings.dart';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;
import 'settings_choice_card.dart';
import 'dart:math' as math;
import 'watched_threshold_settings.dart';
import 'language_settings.dart';
import '../l10n/strings.dart';
import 'settings_navigation.dart';
import 'tmdb_id_guide.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import '../core/debug_log.dart';
import 'metadata_server_settings.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../core/app_theme.dart';
import '../core/metadata.dart';
import 'tmdb_settings_dialog.dart';
import 'tmdb_attribution.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    this.embedded = false,
    this.category,
    this.onClose,
    this.wideLayout,
    this.featureSettings,
  });
  final bool embedded;
  final int? category;
  final VoidCallback? onClose;
  final bool? wideLayout;
  final OptionalFeatures? featureSettings;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

enum _SettingsCategory {
  appearance(0, Icons.palette_outlined),
  language(4, Icons.language),
  scraping(1, Icons.movie_filter_outlined),
  player(5, Icons.play_circle_outline),
  records(3, Icons.history),
  extensions(6, Icons.extension_outlined),
  about(2, Icons.info_outline);

  const _SettingsCategory(this.id, this.icon);
  final int id;
  final IconData icon;

  String label(BuildContext context) => switch (this) {
    appearance => context.l10n.appearance,
    language => context.l10n.language,
    scraping => context.l10n.scraping,
    player => context.l10n.playerSettings,
    records => context.l10n.recordsSync,
    extensions => context.l10n.extensions,
    about => context.l10n.about,
  };
}

class _SettingsPageState extends State<SettingsPage> {
  bool _exportingLogs = false;
  late _SettingsCategory selected;
  bool _exporting = false;
  bool _inspectingBackup = false;

  @override
  void initState() {
    super.initState();
    selected = _SettingsCategory.values.firstWhere(
      (category) => category.id == widget.category,
      orElse: () => _SettingsCategory.appearance,
    );
  }

  Widget _home() => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 12, 16),
        child: Row(
          children: [
            Expanded(
              child: Text(
                context.l10n.settings,
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
              ),
            ),
            if (widget.onClose != null)
              IconButton(
                tooltip: context.l10n.closeSettings,
                onPressed: widget.onClose,
                icon: const Icon(Icons.close),
              ),
          ],
        ),
      ),
      Expanded(
        child: Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              children: [
                for (final category in _SettingsCategory.values)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: ListTile(
                      key: ValueKey('settings-category-${category.id}'),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4),
                        side: BorderSide(
                          color: Theme.of(
                            context,
                          ).dividerColor.withValues(alpha: .1),
                        ),
                      ),
                      leading: Icon(category.icon, size: 26),
                      title: Text(
                        category.label(context),
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).push<void>(
                        MaterialPageRoute(
                          builder: (_) => SettingsPage(
                            embedded: true,
                            category: category.id,
                            featureSettings: widget.featureSettings,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final twoPane =
          widget.wideLayout ??
          (bounds.maxWidth >= 840 && bounds.maxHeight >= 500);
      final content = twoPane || widget.category != null
          ? _content(twoPane: twoPane)
          : _home();
      if (widget.embedded) return Scaffold(body: content);
      return Dialog(
        insetPadding: const EdgeInsets.all(16),
        child: SizedBox(
          width: twoPane ? 1160 : 520,
          height: 780,
          child: content,
        ),
      );
    },
  );

  Widget _content({required bool twoPane}) => SizedBox(
    width: 1160,
    height: 780,
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 12, 12),
          child: Row(
            children: [
              if (widget.category != null && !twoPane)
                IconButton(
                  tooltip: context.l10n.backSettings,
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.arrow_back),
                ),
              Expanded(
                child: Text(
                  twoPane ? context.l10n.settings : selected.label(context),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (!widget.embedded)
                IconButton(
                  tooltip: context.l10n.closeSettings,
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
            ],
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, bounds) {
              final menuStyle = Theme.of(context).textTheme.bodyMedium!
                  .copyWith(fontSize: 17, fontWeight: FontWeight.w600);
              var menuWidth = 240.0;
              for (final category in _SettingsCategory.values) {
                final painter = TextPainter(
                  text: TextSpan(
                    text: category.label(context),
                    style: menuStyle,
                  ),
                  textDirection: Directionality.of(context),
                  textScaler: MediaQuery.textScalerOf(context),
                )..layout();
                // List padding + row padding + icon/gaps + selection arrow.
                menuWidth = math.max(
                  menuWidth,
                  painter.width.ceilToDouble() + 122,
                );
                painter.dispose();
              }
              // Leave a usable content pane; tight layouts use category chips.
              final compact = bounds.maxWidth < menuWidth + 340;
              final menu = ListView(
                padding: const EdgeInsets.fromLTRB(8, 12, 20, 12),
                children: [
                  for (final category in _SettingsCategory.values)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Material(
                        key: ValueKey('settings-category-${category.id}'),
                        color: selected == category
                            ? Theme.of(context).colorScheme.primary
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: () => setState(() {
                            selected = category;
                          }),
                          hoverColor: Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: .035),
                          child: SizedBox(
                            height: 64,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    category.icon,
                                    size: 24,
                                    color: selected == category
                                        ? AppTheme.instance.accent.foreground
                                        : Theme.of(context)
                                              .colorScheme
                                              .onSurface
                                              .withValues(alpha: .6),
                                  ),
                                  const SizedBox(width: 14),
                                  Expanded(
                                    child: Text(
                                      category.label(context),
                                      maxLines: 1,
                                      softWrap: false,
                                      overflow: TextOverflow.ellipsis,
                                      style: menuStyle.copyWith(
                                        color: selected == category
                                            ? AppTheme
                                                  .instance
                                                  .accent
                                                  .foreground
                                            : Theme.of(context)
                                                  .colorScheme
                                                  .onSurface
                                                  .withValues(alpha: .6),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  SizedBox(
                                    width: 20,
                                    child: selected == category
                                        ? Icon(
                                            Icons.chevron_right,
                                            size: 20,
                                            color: AppTheme
                                                .instance
                                                .accent
                                                .foreground,
                                          )
                                        : null,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              );
              final settingsContent = ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  if (selected == _SettingsCategory.scraping) _scrapingHeader(),
                  if (selected != _SettingsCategory.appearance &&
                      selected != _SettingsCategory.about)
                    const SizedBox(height: 24),
                  if (selected == _SettingsCategory.appearance) ...[
                    AnimatedBuilder(
                      animation: AppTheme.instance,
                      builder: (context, _) => SettingsChoiceCard<ThemeMode>(
                        title: context.l10n.themeMode,
                        description: context.l10n.themeDescription,
                        icon: Icons.dark_mode_outlined,
                        value: AppTheme.instance.mode,
                        options: const [
                          ThemeMode.light,
                          ThemeMode.dark,
                          ThemeMode.system,
                        ],
                        label: _modeLabel,
                        selectorKey: const ValueKey('settings-theme-mode'),
                        onChanged: _changeTheme,
                      ),
                    ),
                  ],
                  if (selected == _SettingsCategory.appearance) ...[
                    const SizedBox(height: 16),
                    SettingsPanel(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            context.l10n.accent,
                            style: TextStyle(
                              fontSize: 19,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(context.l10n.accentDescription),
                          const SizedBox(height: 16),
                          Wrap(
                            spacing: 16,
                            runSpacing: 12,
                            children: [
                              for (final accent in ThemeAccent.values)
                                Tooltip(
                                  message: _accentLabel(accent),
                                  child: Semantics(
                                    button: true,
                                    selected:
                                        AppTheme.instance.accent == accent,
                                    label: _accentLabel(accent),
                                    child: InkWell(
                                      key: ValueKey(
                                        'theme-accent-${accent.name}',
                                      ),
                                      borderRadius: BorderRadius.circular(24),
                                      onTap: () async {
                                        try {
                                          await AppTheme.instance.setAccent(
                                            accent,
                                          );
                                        } catch (_) {
                                          if (context.mounted) {
                                            ScaffoldMessenger.of(
                                              context,
                                            ).showSnackBar(
                                              SnackBar(
                                                content: Text(
                                                  context.l10n.accentSaveFailed,
                                                ),
                                              ),
                                            );
                                          }
                                        }
                                      },
                                      child: Container(
                                        width: 48,
                                        height: 48,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: accent.color,
                                          border: Border.all(
                                            color: accent.color.withValues(
                                              alpha: .5,
                                            ),
                                            width: 2,
                                          ),
                                        ),
                                        child:
                                            AppTheme.instance.accent == accent
                                            ? Icon(
                                                Icons.check,
                                                color: accent.foreground,
                                              )
                                            : null,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (selected == _SettingsCategory.scraping) ...[
                    SettingsPanel(
                      child: ListTile(
                        leading: const Icon(Icons.key_outlined),
                        title: Text(context.l10n.tmdbSettings),
                        subtitle: Text(
                          Metadata.credentials.isConfigured
                              ? context.l10n.credentialsConfigured
                              : context.l10n.credentialsMissing,
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () async {
                          await TmdbSettingsDialog.show(context);
                          if (mounted) setState(() {});
                        },
                      ),
                    ),
                    const SizedBox(height: 12),
                    SettingsPanel(
                      child: ListTile(
                        leading: const Icon(Icons.dns_outlined),
                        title: Text(context.l10n.scraping),
                        subtitle: Text(
                          context.l10n.metadataServicesDescription,
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => openSettingsScreen<void>(
                          context,
                          (_) => const MetadataServerSettings(),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    const ImageCacheSettings(),
                    OptionalScrapingSettings(settings: widget.featureSettings),
                  ],
                  if (selected == _SettingsCategory.language)
                    const LanguageSettings(),
                  if (selected == _SettingsCategory.player)
                    const MpvSettingsPanel(),
                  if (selected == _SettingsCategory.extensions)
                    ExtensionsPanel(settings: widget.featureSettings),
                  if (selected == _SettingsCategory.records) ...[
                    const WatchedThresholdSettings(),
                    const SizedBox(height: 16),
                    SettingsPanel(
                      child: ListTile(
                        key: const ValueKey('library-backup-inspect'),
                        leading: const Icon(Icons.fact_check_outlined),
                        title: Text(context.l10n.restoreLibraryBackup),
                        subtitle: Text(
                          context.l10n.restoreLibraryBackupDescription,
                        ),
                        trailing: _inspectingBackup
                            ? const SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.chevron_right),
                        onTap: _inspectingBackup || _exporting
                            ? null
                            : _restoreLibraryBackup,
                      ),
                    ),
                    const SizedBox(height: 16),
                    SettingsPanel(
                      child: ListTile(
                        key: const ValueKey('library-backup-previous'),
                        leading: const Icon(Icons.settings_backup_restore),
                        title: Text(context.l10n.previousLibraryBackup),
                        subtitle: Text(
                          context.l10n.previousLibraryBackupDescription,
                        ),
                        onTap: _inspectingBackup || _exporting
                            ? null
                            : _restorePreviousBackup,
                      ),
                    ),
                    const SizedBox(height: 16),
                    SettingsPanel(
                      child: ListTile(
                        key: const ValueKey('library-backup-export'),
                        leading: const Icon(Icons.archive_outlined),
                        title: Text(context.l10n.exportLibraryBackup),
                        subtitle: Text(
                          context.l10n.exportLibraryBackupDescription,
                        ),
                        trailing: _exporting
                            ? const SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.chevron_right),
                        onTap: _exporting || _inspectingBackup
                            ? null
                            : _exportLibraryBackup,
                      ),
                    ),
                  ],
                  if (selected == _SettingsCategory.about) ...[
                    const Text(
                      'Konata',
                      style: TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(context.l10n.versionLabel),
                    const SizedBox(height: 24),
                    SettingsPanel(
                      child: SwitchListTile(
                        title: Text(context.l10n.enableLogs),
                        subtitle: Text(context.l10n.logsDescription),
                        value: DebugLog.enabled,
                        onChanged: (v) async {
                          try {
                            await DebugLog.setEnabled(v);
                            if (mounted) setState(() {});
                          } catch (_) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(context.l10n.logsSaveFailed),
                                ),
                              );
                            }
                          }
                        },
                      ),
                    ),
                    const SizedBox(height: 16),
                    SettingsPanel(
                      child: ListTile(
                        leading: const Icon(Icons.description_outlined),
                        title: Text(context.l10n.exportLogs),
                        subtitle: Text(context.l10n.exportLogsSystem),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: _exportingLogs ? null : _openLogs,
                      ),
                    ),
                    const SizedBox(height: 24),
                    SettingsPanel(
                      child: ListTile(
                        leading: Image.asset(
                          Theme.of(context).brightness == Brightness.dark
                              ? 'assets/brand/github-white.png'
                              : 'assets/brand/github-black.png',
                          width: 28,
                          height: 28,
                          semanticLabel: 'GitHub',
                        ),
                        title: const Text(
                          'ClainSt/Konata',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: const Text(
                          'https://github.com/ClainSt/Konata',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () async {
                          try {
                            final opened = await launchUrl(
                              Uri.parse('https://github.com/ClainSt/Konata'),
                              mode: LaunchMode.externalApplication,
                            );
                            if (!opened) throw StateError('无法打开浏览器');
                          } catch (_) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(context.l10n.githubOpenFailed),
                                ),
                              );
                            }
                          }
                        },
                      ),
                    ),
                    const SizedBox(height: 24),
                    const TmdbAttribution(),
                  ],
                ],
              );
              final content = settingsContent;
              if (!twoPane) return content;
              if (compact) {
                return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Wrap(
                        spacing: 8,
                        children: [
                          for (final category in _SettingsCategory.values)
                            ChoiceChip(
                              label: Text(category.label(context)),
                              selected: selected == category,
                              onSelected: (_) => setState(() {
                                selected = category;
                              }),
                            ),
                        ],
                      ),
                    ),
                    Expanded(child: content),
                  ],
                );
              }
              return Row(
                children: [
                  SizedBox(width: menuWidth, child: menu),

                  Expanded(child: content),
                ],
              );
            },
          ),
        ),
      ],
    ),
  );

  Future<LibraryBackupRestorer> _restorer() async => LibraryBackupRestorer(
    database: Catalog.instance.db,
    artworkDirectory: await ImageStore.directory(),
    preferences: await SharedPreferences.getInstance(),
  );

  Future<void> _restorePreviousBackup() async {
    try {
      final backups = await (await _restorer()).recoveryBackups();
      if (!mounted) return;
      if (backups.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.noPreviousLibraryBackup)),
        );
        return;
      }
      final file = await showDialog<File>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: Text(ctx.l10n.previousLibraryBackup),
          children: [
            for (final file in backups)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, file),
                child: Text(
                  DateTime.fromMicrosecondsSinceEpoch(
                    int.parse(
                      p
                          .basename(file.path)
                          .replaceFirst('before-restore-', '')
                          .replaceFirst('.zip', ''),
                    ),
                  ).toLocal().toString(),
                ),
              ),
          ],
        ),
      );
      if (file != null && mounted) await _restoreLibraryBackup(file);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.restoreLibraryBackupFailed)),
        );
      }
    }
  }

  Future<void> _restoreLibraryBackup([File? input]) async {
    if (_inspectingBackup) return;
    setState(() => _inspectingBackup = true);
    PreparedLibraryBackup? prepared;
    try {
      if (Catalog.instance.scanning) throw StateError('Scan running');
      if (input == null) {
        final picked = await FilePicker.pickFile(
          type: FileType.custom,
          allowedExtensions: const ['zip'],
        );
        if (picked == null || !mounted) return;
        final path = picked.path;
        if (path == null) {
          throw const FileSystemException('No readable backup file');
        }
        input = File(path);
      }
      prepared = await (await _restorer()).prepare(input);
      final preview = prepared.preview;
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(context.l10n.restoreLibraryBackup),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(context.l10n.restoreCurrentLibrary),
                Text(
                  '${Catalog.instance.works.length + Catalog.instance.hiddenWorkEntries.length} / '
                  '${Catalog.instance.assets.length} / ${Catalog.instance.sources.length}',
                ),
                const SizedBox(height: 12),
                Text(preview.createdAt.toLocal().toString()),
                const SizedBox(height: 12),
                Text(context.l10n.backupPreviewCounts),
                Text(
                  '${preview.works} / ${preview.assets} / ${preview.sources} / ${preview.history} / ${preview.artwork}',
                ),
                const SizedBox(height: 12),
                Text(context.l10n.restoreLibraryBackupWarning),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(
                MaterialLocalizations.of(dialogContext).cancelButtonLabel,
              ),
            ),
            FilledButton(
              key: const ValueKey('library-backup-confirm'),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(context.l10n.restoreLibraryBackup),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      if (Catalog.instance.scanning) throw StateError('Scan running');
      Catalog.instance.scanning = true;
      final navigator = Navigator.of(context, rootNavigator: true);
      final progress = DialogRoute<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => PopScope(
          canPop: false,
          child: AlertDialog(
            content: Row(
              children: [
                const CircularProgressIndicator(),
                const SizedBox(width: 20),
                Expanded(child: Text(ctx.l10n.restoringLibraryBackup)),
              ],
            ),
          ),
        ),
      );
      unawaited(navigator.push(progress));
      try {
        await (await _restorer()).restore(prepared);
        await Catalog.instance.reload();
        await AppTheme.instance.load();
        await ArtworkSettings.instance.load();
        await AppLanguage.instance.load();
        await WatchSettings.instance.load();
      } finally {
        Catalog.instance.scanning = false;
        if (progress.isActive) navigator.removeRoute(progress);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.restoreLibraryBackupDone)),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              Catalog.instance.scanning
                  ? context.l10n.restoreLibraryBackupBusy
                  : context.l10n.restoreLibraryBackupFailed,
            ),
          ),
        );
      }
    } finally {
      await prepared?.dispose();
      if (mounted) setState(() => _inspectingBackup = false);
    }
  }

  Future<void> _exportLibraryBackup() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    Directory? temporary;
    try {
      temporary = await (await getTemporaryDirectory()).createTemp('ccplayer-backup-');
      final archive = File(p.join(temporary.path, 'ccplayer-library.zip'));
      final exporter = LibraryBackupExporter(
        database: Catalog.instance.db,
        artworkDirectory: await ImageStore.directory(),
        preferences: await SharedPreferences.getInstance(),
      );
      await exporter.export(archive);
      // Android's saveFile API uses bytes; bound memory for export.
      if (await archive.length() > 64 * 1024 * 1024) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.l10n.exportLibraryBackupTooLarge)),
          );
        }
        return;
      }
      final bytes = await archive.readAsBytes();
      if (!mounted) return;
      final savedPath = await FilePicker.saveFile(
        dialogTitle: context.l10n.exportLibraryBackup,
        fileName:
            'Konata-library-${DateTime.now().toIso8601String().substring(0, 10)}.zip',
        bytes: bytes,
      );
      if (savedPath != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.exportLibraryBackupDone)),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.exportLibraryBackupFailed)),
        );
      }
    } finally {
      if (temporary != null) {
        try {
          await temporary.delete(recursive: true);
        } catch (_) {}
      }
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _openLogs() async {
    if (_exportingLogs) return;
    setState(() => _exportingLogs = true);
    try {
      if (DebugLog.directory == null) await DebugLog.initialize();
      final text = await DebugLog.latestIncidentText();
      if (!mounted) return;
      if (text == null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.l10n.noLogs)));
        return;
      }
      await FilePicker.saveFile(
        dialogTitle: context.l10n.exportLogs,
        fileName:
            'Konata-incident-${DateTime.now().toUtc().millisecondsSinceEpoch}.txt',
        bytes: Uint8List.fromList(utf8.encode(text)),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.l10n.logsAccessFailed)));
      }
    } finally {
      if (mounted) setState(() => _exportingLogs = false);
    }
  }

  Widget _scrapingHeader() => Align(
    alignment: Alignment.centerRight,
    child: TextButton.icon(
      key: const ValueKey('tmdb-id-guide'),
      onPressed: () => TmdbIdGuide.show(context),
      icon: const Icon(Icons.help_outline, size: 18),
      label: Text(context.l10n.tmdbIdGuide, style: TextStyle(fontSize: 14)),
    ),
  );

  String _accentLabel(ThemeAccent accent) => switch (accent) {
    ThemeAccent.sage => context.l10n.sage,
    ThemeAccent.red => context.l10n.red,
    ThemeAccent.pink => context.l10n.pink,
    ThemeAccent.lightBlue => context.l10n.lightBlue,
  };

  String _modeLabel(ThemeMode mode) => switch (mode) {
    ThemeMode.light => context.l10n.dayMode,
    ThemeMode.dark => context.l10n.nightMode,
    ThemeMode.system => context.l10n.followSystem,
  };

  Future<void> _changeTheme(ThemeMode mode) async {
    try {
      await AppTheme.instance.setMode(mode);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.l10n.themeSaveFailed)));
      }
    }
  }
}
