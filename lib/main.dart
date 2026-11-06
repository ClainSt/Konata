import 'core/player_fullscreen.dart';
import 'core/mpv_config_store.dart';
import 'core/mpv_engine_store.dart';
import 'l10n/strings.dart';
import 'ui/uniform_action_bar.dart';
import 'core/app_language.dart';
import 'core/watch_settings.dart';
import 'l10n/app_localizations.dart';
import 'core/image_store.dart';
import 'dart:ui' as ui;
import 'core/metadata_servers.dart';
import 'core/metadata_http.dart';
import 'core/debug_log.dart';
import 'ui/managed_image.dart';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:media_kit/media_kit.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:window_manager/window_manager.dart';
import 'core/app_theme.dart';
import 'ui/app_header.dart';
import 'ui/settings_page.dart';
import 'ui/add_media_dialog.dart';
import 'core/sources.dart';
import 'core/catalog.dart';
import 'core/metadata.dart';

import 'ui/source_browser_page.dart';
import 'ui/poster_title.dart';
import 'ui/source_editor.dart';
import 'ui/nipaplay_detail_page.dart';
import 'ui/nipaplay_style.dart';
import 'ui/work_edit_dialogs.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (AppHeader.desktop) {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        title: 'Konata',
        minimumSize: Size(640, 480),
        titleBarStyle: TitleBarStyle.hidden,
        windowButtonVisibility: false,
      ),
    );
  }
  await MetadataServers.load();
  await MetadataHttp.initialize();
  await ImageStore.directory();
  await DebugLog.initialize();
  final previousError = FlutterError.onError;
  FlutterError.onError = (details) {
    DebugLog.write(
      'App',
      'Flutter error ${details.exception.runtimeType}',
      level: 'ERROR',
    );
    previousError?.call(details);
  };
  ui.PlatformDispatcher.instance.onError = (error, stack) {
    DebugLog.write('App', 'uncaught ${error.runtimeType}', level: 'ERROR');
    return false;
  };
  await AppTheme.instance.load();
  await AppLanguage.instance.load();
  await WatchSettings.instance.load();
  await MpvConfigStore.instance.initialize();
  final engineStore = MpvEngineStore.instance;
  await engineStore.initialize();
  final enhancedLibrary = await engineStore.preferredStartupLibrary();
  if (enhancedLibrary != null) {
    try {
      MediaKit.ensureInitialized(libmpv: enhancedLibrary);
      engineStore.recordStartupResult(enhanced: true);
    } catch (error) {
      // If an optional native build is unavailable, retain default playback.
      DebugLog.write(
        'MPV',
        'optional engine init failed: ${error.runtimeType}',
        level: 'ERROR',
      );
      MediaKit.ensureInitialized();
      engineStore.recordStartupResult(enhanced: false);
    }
  } else {
    MediaKit.ensureInitialized();
    engineStore.recordStartupResult(enhanced: false);
  }
  await Catalog.instance.initialize();
  const secure = FlutterSecureStorage();
  Metadata.token = (await secure.read(key: 'tmdb_token')) ?? '';
  Metadata.apiKey = (await secure.read(key: 'tmdb_api_key')) ?? '';
  Metadata.authMode = (await secure.read(key: 'tmdb_auth_mode')) == 'apiKey'
      ? 'apiKey'
      : 'token';
  runApp(const CCPlayer());
}

final libraryDestination = ValueNotifier<bool>(false);

class CCPlayer extends StatefulWidget {
  const CCPlayer({super.key, this.mobile});
  final bool? mobile;
  @override
  State<CCPlayer> createState() => _CCPlayerState();
}

class _CCPlayerState extends State<CCPlayer> {
  final navigatorKey = GlobalKey<NavigatorState>();
  bool settingsSelected = false;
  bool settingsDialogOpen = false;
  bool get mobile => widget.mobile ?? !AppHeader.desktop;
  Widget _navigation() => ValueListenableBuilder<bool>(
    valueListenable: libraryDestination,
    builder: (context, sources, _) => ValueListenableBuilder<PlayingHeader?>(
      valueListenable: playingHeader,
      builder: (context, playback, _) => playback?.videoOverlay == true
          ? const SizedBox.shrink()
          : AppHeader(
              playbackTitle: playback?.title,
              onPlaybackBack: playback?.onBack,
              showSources: sources,
              mobile: mobile,
              settingsSelected: settingsSelected,
              onNavigate: (value) {
                navigatorKey.currentState?.popUntil((route) => route.isFirst);
                setState(() => settingsSelected = false);
                libraryDestination.value = value;
              },
              onSettings: () {
                if (!mobile) {
                  if (settingsDialogOpen) return;
                  settingsDialogOpen = true;
                  showDialog<void>(
                    context: navigatorKey.currentContext!,
                    builder: (_) => const SettingsPage(wideLayout: true),
                  ).whenComplete(() => settingsDialogOpen = false);
                  return;
                }
                navigatorKey.currentState?.popUntil((route) => route.isFirst);
                setState(() => settingsSelected = true);
              },
            ),
    ),
  );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([AppTheme.instance, AppLanguage.instance]),
    builder: (context, _) => MaterialApp(
      navigatorKey: navigatorKey,
      title: 'Konata',
      locale: AppLanguage.instance.locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      localeListResolutionCallback: AppLanguage.resolve,
      debugShowCheckedModeBanner: false,
      theme: NipaPlayStyle.theme(Brightness.light),
      darkTheme: NipaPlayStyle.theme(Brightness.dark),
      themeMode: AppTheme.instance.mode,
      builder: (context, child) => ValueListenableBuilder<bool>(
        valueListenable: playerFullscreen,
        builder: (context, fullscreen, _) => ColoredBox(
          color: Theme.of(context).scaffoldBackgroundColor,
          child: SafeArea(
            top: mobile && !fullscreen,
            bottom: false,
            child: Overlay.wrap(
              child: Column(
                children: [
                  if (!mobile)
                    fullscreen ? const SizedBox.shrink() : _navigation(),
                  Expanded(child: child!),
                  if (mobile)
                    fullscreen ? const SizedBox.shrink() : _navigation(),
                ],
              ),
            ),
          ),
        ),
      ),
      home: PopScope(
        canPop: !settingsSelected,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop && settingsSelected) {
            setState(() => settingsSelected = false);
          }
        },
        child: IndexedStack(
          index: settingsSelected ? 1 : 0,
          children: [
            LibraryPage(mobile: mobile),
            SettingsPage(
              embedded: true,
              onClose: mobile
                  ? null
                  : () => setState(() => settingsSelected = false),
            ),
          ],
        ),
      ),
    ),
  );
}

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key, this.mobile = false});
  final bool mobile;
  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  bool searchOpen = false;
  final searchController = TextEditingController();
  bool get showSources => libraryDestination.value;
  @override
  void initState() {
    super.initState();
    libraryDestination.addListener(_destinationChanged);
  }

  void _destinationChanged() => setState(() {});
  @override
  void dispose() {
    searchController.dispose();
    libraryDestination.removeListener(_destinationChanged);
    super.dispose();
  }

  String filter = '';
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Catalog.instance,
    builder: (ctx, _) {
      final cat = Catalog.instance;
      final matches = cat.works
          .where(
            (w) => w['title'].toString().toLowerCase().contains(
              filter.toLowerCase(),
            ),
          )
          .toList();
      return Scaffold(
        body: Column(
          children: [
            if (cat.scanning) const LinearProgressIndicator(),
            _libraryToolbar(cat),
            Expanded(
              child: showSources
                  ? _sources(cat)
                  : matches.isEmpty
                  ? Center(
                      child: Text(
                        cat.sources.isEmpty
                            ? context.l10n.addSourceFirst
                            : context.l10n.noMatchingTitles,
                      ),
                    )
                  : LayoutBuilder(
                      builder: (ctx, bounds) {
                        // Poster-first cards: only a 2:3 cover and one compact title line.
                        const horizontalPadding = 14.0;
                        const crossSpacing = 12.0;
                        const preferredPosterWidth = 164.0;
                        final available =
                            bounds.maxWidth - 2 * horizontalPadding;
                        final columns = available > 0
                            ? ((available + crossSpacing) /
                                      (preferredPosterWidth + crossSpacing))
                                  .ceil()
                            : 1;
                        final cardWidth =
                            (bounds.maxWidth -
                                2 * horizontalPadding -
                                (columns - 1) * crossSpacing) /
                            columns;
                        final cardHeight =
                            cardWidth * 1.5 + 8 + _posterTitleHeight;
                        return GridView.builder(
                          padding: const EdgeInsets.all(horizontalPadding),
                          itemCount: matches.length,
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: columns,
                                mainAxisExtent: cardHeight,
                                crossAxisSpacing: crossSpacing,
                                mainAxisSpacing: 16,
                              ),
                          itemBuilder: (ctx, i) => _poster(matches[i]),
                        );
                      },
                    ),
            ),
          ],
        ),
      );
    },
  );
  Widget _libraryToolbar(Catalog cat) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
    child: LayoutBuilder(
      builder: (context, bounds) {
        final toolbarHeight =
            (MediaQuery.textScalerOf(context).scale(16) * 1.5 + 20).clamp(
              48.0,
              double.infinity,
            );
        final search = SizedBox(
          height: toolbarHeight,
          child: TextField(
            controller: searchController,
            autofocus: true,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: .7),
            ),
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search, size: 20),
              hintText: context.l10n.searchTitles,
              hintStyle: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: .7),
              ),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 10,
              ),
              fillColor: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: .045),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
            onChanged: (value) => setState(() => filter = value),
          ),
        );
        final row = Row(
          children: [
            if (!showSources && searchOpen && bounds.maxWidth < 700)
              Expanded(child: search)
            else ...[
              Text(
                showSources
                    ? context.l10n.sourceCount(cat.sources.length)
                    : context.l10n.workCount(cat.works.length),
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: .7),
                ),
              ),
              const Spacer(),
            ],
            if (!showSources && searchOpen && bounds.maxWidth >= 700) ...[
              SizedBox(width: 280, child: search),
              const SizedBox(width: 16),
            ],
            if (cat.hiddenWorkEntries.isNotEmpty &&
                !(searchOpen && bounds.maxWidth < 700))
              IconButton(
                key: const ValueKey('manage-hidden-works-button'),
                onPressed: _manageHiddenWorks,
                tooltip: context.l10n.manageHidden,
                icon: const Icon(Icons.visibility_off_outlined),
              ),
            if (!showSources)
              IconButton(
                key: const ValueKey('library-search-toggle'),
                style: IconButton.styleFrom(
                  fixedSize: Size(toolbarHeight, toolbarHeight),
                ),
                tooltip: searchOpen
                    ? context.l10n.closeSearch
                    : context.l10n.searchTitles,
                icon: Icon(searchOpen ? Icons.close : Icons.search),
                onPressed: () => setState(() {
                  searchOpen = !searchOpen;
                  if (!searchOpen) {
                    filter = '';
                    searchController.clear();
                  }
                }),
              ),
            if (showSources)
              Tooltip(
                message: context.l10n.addSource,
                child: TextButton.icon(
                  style: ButtonStyle(
                    foregroundColor: WidgetStateProperty.resolveWith(
                      (states) =>
                          states.contains(WidgetState.hovered) ||
                              states.contains(WidgetState.focused) ||
                              states.contains(WidgetState.pressed)
                          ? NipaPlayStyle.accent
                          : Theme.of(
                              context,
                            ).colorScheme.onSurface.withValues(alpha: .7),
                    ),
                    overlayColor: const WidgetStatePropertyAll(
                      Colors.transparent,
                    ),
                    textStyle: const WidgetStatePropertyAll(
                      TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                  ),
                  onPressed: _add,
                  icon: const Icon(Icons.add, size: 20),
                  label: Text(context.l10n.addSource),
                ),
              ),
          ],
        );
        return SizedBox(
          key: const ValueKey('library-toolbar-row'),
          height: toolbarHeight,
          child: row,
        );
      },
    ),
  );
  double get _posterTitleHeight =>
      MediaQuery.textScalerOf(context).scale(16) * 1.5 + 2;

  Widget _poster(Map<String, Object?> work) => InkWell(
    onTap: () => Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => WorkPage(workId: work['id'].toString()),
      ),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AspectRatio(
          key: ValueKey('library-poster-${work['id']}'),
          aspectRatio: 2 / 3,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Catalog.preferredPoster(work) != null
                ? ManagedImage(
                    Catalog.preferredPoster(work)!,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) {
                      final fallback = work['poster_fallback']?.toString();
                      if (fallback == null ||
                          fallback.isEmpty ||
                          fallback == work['poster']) {
                        return _blankPoster();
                      }
                      return ManagedImage(
                        fallback,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => _blankPoster(),
                      );
                    },
                  )
                : _blankPoster(),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: _posterTitleHeight,
          child: Align(
            alignment: Alignment.topLeft,
            child: PosterTitle(
              key: ValueKey('library-title-${work['id']}'),
              title: work['title'].toString(),
            ),
          ),
        ),
      ],
    ),
  );
  Widget _blankPoster() => const ColoredBox(
    color: Color(0xffeeeeee),
    child: Center(
      child: Icon(Icons.movie_outlined, color: Colors.grey, size: 46),
    ),
  );

  void _browse(Map<String, Object?> source) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => SourceBrowserPage(source: source)),
    );
  }

  Widget _sources(Catalog cat) => ListView(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
    children: [
      for (final source in cat.sources)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Align(
            alignment: Alignment.topLeft,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.sizeOf(context).width < 600
                    ? MediaQuery.sizeOf(context).width - 40
                    : ((MediaQuery.sizeOf(context).width - 40) / 2).clamp(
                        560.0,
                        MediaQuery.sizeOf(context).width - 40,
                      ),
              ),
              child: Card(
                clipBehavior: Clip.antiAlias,
                margin: EdgeInsets.zero,
                child: InkWell(
                  onTap: () => _browse(source),
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: LayoutBuilder(
                      builder: (context, bounds) {
                        final info = Row(
                          children: [
                            Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: Theme.of(
                                  context,
                                ).colorScheme.primary.withValues(alpha: .09),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(
                                source['kind'] == 'local'
                                    ? Icons.folder_outlined
                                    : Icons.cloud_outlined,
                                size: 23,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    source['label'].toString(),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 5),
                                  Text(
                                    '${source['kind'] == 'local'
                                        ? context.l10n.localDirectory
                                        : source['kind'] == 'smb'
                                        ? 'SMB'
                                        : 'WebDAV'} · ${source['location']}',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      height: 1.5,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurface
                                          .withValues(alpha: .55),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        );
                        final actions = Wrap(
                          children: [
                            IconButton(
                              tooltip: context.l10n.editSource,
                              icon: const Icon(Icons.edit_outlined),
                              onPressed: () =>
                                  SourceEditor.show(context, source),
                            ),
                            IconButton(
                              tooltip: context.l10n.browseScanFolders,
                              onPressed: () => _browse(source),
                              icon: const Icon(Icons.folder_open_outlined),
                            ),
                            IconButton(
                              tooltip: context.l10n.remove,
                              onPressed: () async {
                                final ok = await showDialog<bool>(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    title: Text(context.l10n.removeSourceTitle),
                                    content: Text(
                                      context.l10n.removeSourceBody,
                                    ),
                                    actions: [
                                      UniformActionBar(
                                        children: [
                                          TextButton(
                                            onPressed: () =>
                                                Navigator.pop(ctx, false),
                                            child: Text(context.l10n.cancel),
                                          ),
                                          FilledButton(
                                            onPressed: () =>
                                                Navigator.pop(ctx, true),
                                            child: Text(context.l10n.remove),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                );
                                if (ok == true) {
                                  await Catalog.instance.removeSource(
                                    source['id'].toString(),
                                  );
                                }
                              },
                              icon: const Icon(Icons.delete_outline),
                            ),
                          ],
                        );
                        return bounds.maxWidth >= 420
                            ? Row(
                                children: [
                                  Expanded(child: info),
                                  const SizedBox(width: 20),
                                  actions,
                                ],
                              )
                            : Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  info,
                                  const SizedBox(height: 10),
                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: actions,
                                  ),
                                ],
                              );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
    ],
  );
  Future<void> _add() async {
    final kind = await AddMediaDialog.show(context);
    if (kind == null || !mounted) return;
    final name = TextEditingController(),
        location = TextEditingController(),
        username = TextEditingController(),
        password = TextEditingController();
    bool obscurePassword = true;
    InputDecoration fieldDecoration(String label, {Widget? suffixIcon}) =>
        InputDecoration(
          labelText: label,
          suffixIcon: suffixIcon,
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: .25),
            ),
          ),
        );
    try {
      final route = DialogRoute<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, update) => AlertDialog(
            titlePadding: const EdgeInsets.fromLTRB(24, 20, 12, 8),
            contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
            actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
            title: Row(
              children: [
                Expanded(
                  child: Text(
                    kind == 'local'
                        ? ctx.l10n.addLocalTitle
                        : kind == 'smb'
                        ? ctx.l10n.addSmb
                        : ctx.l10n.addWebdav,
                  ),
                ),
                IconButton(
                  tooltip: ctx.l10n.closeWindow,
                  onPressed: () => Navigator.pop(ctx, false),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            content: SizedBox(
              width: 460,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (kind != 'local') ...[
                      Text(
                        ctx.l10n.sourceConnectHint,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Theme.of(
                            ctx,
                          ).colorScheme.onSurface.withValues(alpha: .65),
                        ),
                      ),
                      const SizedBox(height: 24),
                    ],
                    TextField(
                      controller: name,
                      decoration: fieldDecoration(ctx.l10n.connectionName),
                    ),
                    if (kind == 'local')
                      Padding(
                        padding: EdgeInsets.symmetric(vertical: 18),
                        child: Text(ctx.l10n.folderPickerHint),
                      ),
                    if (kind != 'local') ...[
                      const SizedBox(height: 16),
                      TextField(
                        controller: location,
                        decoration: fieldDecoration(
                          kind == 'smb'
                              ? ctx.l10n.smbUrlHint
                              : ctx.l10n.webdavUrl,
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: username,
                        decoration: fieldDecoration(
                          kind == 'smb'
                              ? ctx.l10n.smbUsername
                              : ctx.l10n.usernameCreate,
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: password,
                        obscureText: obscurePassword,
                        decoration: fieldDecoration(
                          ctx.l10n.passwordOptional,
                          suffixIcon: IconButton(
                            tooltip: obscurePassword
                                ? ctx.l10n.showPassword
                                : ctx.l10n.hidePassword,
                            onPressed: () => update(
                              () => obscurePassword = !obscurePassword,
                            ),
                            icon: Icon(
                              obscurePassword
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        ctx.l10n.guestHint,
                        style: TextStyle(
                          color: Theme.of(
                            ctx,
                          ).colorScheme.onSurface.withValues(alpha: .6),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              UniformActionBar(
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: Text(ctx.l10n.cancel),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: Text(ctx.l10n.add),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
      final confirmed = await Navigator.of(
        context,
        rootNavigator: true,
      ).push<bool>(route);
      await route.completed;
      if (!mounted) return;
      if (confirmed == true) {
        if (kind == 'local') {
          final chosen = await FilePicker.getDirectoryPath(
            dialogTitle: context.l10n.chooseMediaFolder,
          );
          if (!mounted) return;
          if (chosen != null && chosen.isNotEmpty) {
            final id = await Catalog.instance.addSource(
              'local',
              name.text.trim().isEmpty
                  ? p.basename(p.normalize(chosen))
                  : name.text.trim(),
              chosen,
            );
            if (mounted) _browse(Catalog.instance.sourceOf(id));
          }
        } else if (location.text.trim().isNotEmpty) {
          if (username.text.trim().isEmpty && password.text.isNotEmpty) {
            _message(context.l10n.anonymousCredentials);
            return;
          }
          final uri = Uri.tryParse(location.text.trim());
          if (kind == 'smb') {
            try {
              SmbSource.validateLocation(location.text.trim());
              final id = await Catalog.instance.addSource(
                'smb',
                name.text.trim().isEmpty ? uri!.host : name.text.trim(),
                location.text.trim(),
                username: username.text.trim(),
                password: password.text,
              );
              if (mounted) _browse(Catalog.instance.sourceOf(id));
            } catch (e) {
              if (mounted) _message(context.l10n.sourceAddFailed);
            }
          } else if (uri == null ||
              !uri.hasAuthority ||
              (uri.scheme != 'http' && uri.scheme != 'https')) {
            _message(context.l10n.invalidWebdav);
          } else {
            final id = await Catalog.instance.addSource(
              'webdav',
              name.text.trim().isEmpty ? uri.host : name.text.trim(),
              location.text.trim(),
              username: username.text.trim(),
              password: password.text,
            );
            if (mounted) _browse(Catalog.instance.sourceOf(id));
          }
        }
      }
    } finally {
      name.dispose();
      location.dispose();
      username.dispose();
      password.dispose();
    }
  }

  Future<void> _manageHiddenWorks() => showDialog<void>(
    context: context,
    builder: (dialogContext) => AnimatedBuilder(
      animation: Catalog.instance,
      builder: (context, _) {
        final hidden = Catalog.instance.hiddenWorkEntries;
        return AlertDialog(
          title: Text(context.l10n.manageHidden),
          content: SizedBox(
            width: 560,
            height: 350,
            child: hidden.isEmpty
                ? Center(child: Text(context.l10n.noHiddenTitles))
                : ListView.builder(
                    itemCount: hidden.length,
                    itemBuilder: (context, index) {
                      final work = hidden[index];
                      return ListTile(
                        title: Text(work['title']?.toString() ?? ''),
                        subtitle: Text(
                          work['keep_hidden'] == 1
                              ? context.l10n.keepHidden
                              : context.l10n.restoreOnScan,
                        ),
                        trailing: TextButton.icon(
                          onPressed: () async {
                            await Catalog.instance.restoreWork(
                              work['id'].toString(),
                            );
                          },
                          icon: const Icon(Icons.visibility_outlined),
                          label: Text(context.l10n.restoreTitle),
                        ),
                      );
                    },
                  ),
          ),
          actions: [
            UniformActionBar(
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: Text(context.l10n.closeWindow),
                ),
              ],
            ),
          ],
        );
      },
    ),
  );

  void _message(String message) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }
}

class WorkPage extends StatefulWidget {
  const WorkPage({super.key, required this.workId});
  final String workId;
  @override
  State<WorkPage> createState() => _WorkPageState();
}

class _WorkPageState extends State<WorkPage> {
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Catalog.instance,
    builder: (ctx, _) {
      final cat = Catalog.instance;
      final found = cat.works.where((w) => w['id'] == widget.workId).toList();
      if (found.isEmpty) {
        return Scaffold(body: Center(child: Text(context.l10n.titleNotFound)));
      }
      final work = found.first;
      return NipaPlayDetailPage(
        work: work,
        assets: cat.forWork(widget.workId),
        onEditMetadata: () => WorkEditDialogs.metadata(
          context,
          work,
          searchAndBind: () => _match(work),
        ),
        onEditCover: () => WorkEditDialogs.cover(context, work),
        onDelete: () => _deleteWork(work),
        onBack: () => Navigator.maybePop(context),
      );
    },
  );

  Future<void> _deleteWork(Map<String, Object?> work) async {
    if (Catalog.instance.scanning) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.scanBeforeRemove)));
      return;
    }
    var keepHidden = false;
    final decision = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, update) => AlertDialog(
          title: Text(context.l10n.removeWorkTitle),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(work['title']?.toString() ?? ''),
                const SizedBox(height: 12),
                Text(context.l10n.removeWorkBody),
                const SizedBox(height: 10),
                CheckboxListTile(
                  key: const ValueKey('keep-work-hidden-checkbox'),
                  value: keepHidden,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(context.l10n.keepHidden),
                  subtitle: Text(context.l10n.rescanRestoresHint),
                  onChanged: (value) =>
                      update(() => keepHidden = value ?? false),
                ),
              ],
            ),
          ),
          actions: [
            UniformActionBar(
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: Text(context.l10n.cancel),
                ),
                FilledButton(
                  key: const ValueKey('confirm-remove-work'),
                  onPressed: () => Navigator.pop(dialogContext, keepHidden),
                  child: Text(context.l10n.removeFromLibrary),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    if (decision == null || !mounted) return;
    try {
      await Catalog.instance.hideWork(widget.workId, keepHidden: decision);
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.l10n.removeWorkFailed)));
      }
    }
  }

  Future<void> _match(Map<String, Object?> work) async {
    final query = TextEditingController(
      text: Catalog.cleanTitle(work['title'].toString()),
    );
    String provider = 'tmdb';
    bool loading = false;
    String? failure;
    List<Candidate> results = [];
    final route = DialogRoute<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => AlertDialog(
          title: Text(ctx.l10n.manualMatch),
          content: SizedBox(
            width: 540,
            height: 490,
            child: Column(
              children: [
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'tmdb', label: Text('TMDB')),
                    ButtonSegment(value: 'bangumi', label: Text('Bangumi')),
                  ],
                  selected: {provider},
                  onSelectionChanged: (v) => update(() {
                    provider = v.first;
                    results = [];
                  }),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: query,
                        decoration: InputDecoration(
                          labelText: ctx.l10n.nameOrId,
                        ),
                      ),
                    ),
                    IconButton.filled(
                      tooltip: ctx.l10n.search,
                      icon: const Icon(Icons.search),
                      onPressed: loading
                          ? null
                          : () async {
                              update(() {
                                loading = true;
                                failure = null;
                              });
                              try {
                                final items = await Metadata.search(
                                  query.text,
                                  provider,
                                );
                                if (!ctx.mounted) return;
                                update(() {
                                  results = items;
                                  loading = false;
                                });
                              } catch (e) {
                                DebugLog.write(
                                  'Match',
                                  'search failed ${e.runtimeType}',
                                  level: 'WARN',
                                );
                                if (!ctx.mounted) return;
                                update(() {
                                  loading = false;
                                  failure = 'search';
                                });
                              }
                            },
                    ),
                  ],
                ),
                if (loading) const LinearProgressIndicator(),
                if (failure != null)
                  Text(
                    failure == 'search'
                        ? ctx.l10n.searchFailed
                        : ctx.l10n.bindFailed,
                    style: const TextStyle(color: Colors.orangeAccent),
                  ),
                Expanded(
                  child: ListView(
                    children: [
                      for (final result in results)
                        ListTile(
                          leading: result.poster == null
                              ? const Icon(Icons.movie)
                              : ManagedImage(
                                  result.poster!,
                                  width: 45,
                                  height: 65,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, _, _) =>
                                      const Icon(Icons.movie),
                                ),
                          title: Text(result.title),
                          subtitle: Text(
                            '${result.year?.toString() ?? '?'} · ${result.provider} #${result.id}',
                          ),
                          trailing: const Icon(Icons.link),
                          onTap: loading
                              ? null
                              : () async {
                                  update(() {
                                    loading = true;
                                    failure = null;
                                  });
                                  try {
                                    await Catalog.instance.bind(
                                      widget.workId,
                                      provider: result.provider,
                                      providerId: result.id,
                                      title: result.title,
                                      year: result.year,
                                      poster: result.poster,
                                      overview: result.overview,
                                      type: result.mediaType,
                                    );
                                    if (ctx.mounted) Navigator.pop(ctx);
                                  } catch (e) {
                                    DebugLog.write(
                                      'Match',
                                      'bind failed ${e.runtimeType}',
                                      level: 'WARN',
                                    );
                                    if (ctx.mounted) {
                                      update(() {
                                        loading = false;
                                        failure = 'bind';
                                      });
                                    }
                                  }
                                },
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            UniformActionBar(
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(ctx.l10n.closeWindow),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    await Navigator.of(context, rootNavigator: true).push<void>(route);
    await route.completed;
    query.dispose();
  }
}
