import 'core/player_fullscreen.dart';
import 'core/optional_features.dart';
import 'core/mpv_config_store.dart';
import 'l10n/strings.dart';
import 'ui/uniform_action_bar.dart';
import 'core/app_language.dart';
import 'core/watch_settings.dart';
import 'l10n/app_localizations.dart';
import 'core/image_store.dart';
import 'core/artwork_settings.dart';
import 'dart:ui' as ui;
import 'dart:io';
import 'core/metadata_servers.dart';
import 'core/metadata_http.dart';
import 'core/debug_log.dart';
import 'ui/managed_image.dart';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:media_kit/media_kit.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:window_manager/window_manager.dart';
import 'core/app_theme.dart';
import 'ui/app_header.dart';
import 'ui/settings_page.dart';
import 'core/sources.dart';
import 'core/catalog.dart';
import 'core/local_media.dart';
import 'package:android_file_picker/android_file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'core/metadata.dart';
import 'core/scrape_task_runner.dart';
import 'ui/scrape_tasks_page.dart';

import 'ui/source_browser_page.dart';
import 'ui/poster_title.dart';
import 'ui/source_editor.dart';
import 'ui/nipaplay_detail_page.dart';
import 'ui/nipaplay_style.dart';
import 'ui/konata_motion.dart';
import 'ui/playback_history_page.dart';
import 'ui/library_source_filter.dart';
import 'ui/work_edit_dialogs.dart';

Future<void> main() => launchKonata();

Future<void> launchKonata({
  Directory? scraperValidationDirectory,
  bool experimentalScraping = false,
}) async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    // Complete portable-data migration before preferences, cache or SQLite open.
    await getApplicationSupportDirectory();
  } catch (_) {
    runApp(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: SelectableText(
                '无法打开 Konata 数据目录。请关闭其他 Konata 实例，并将整个程序文件夹移到可写位置后重试。旧数据未删除。\n\n'
                'Cannot open Konata data. Close other copies and move the whole folder to a writable location. Existing data has been preserved.',
              ),
            ),
          ),
        ),
      ),
    );
    return;
  }
  if (AppHeader.desktop) {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      WindowOptions(
        title: scraperValidationDirectory == null
            ? 'Konata'
            : 'Konata Scraper Test',
        minimumSize: const Size(640, 480),
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
    DebugLog.exception(
      'App',
      'flutter_error',
      details.exception,
      details.stack,
    );
    previousError?.call(details);
  };
  ui.PlatformDispatcher.instance.onError = (error, stack) {
    DebugLog.exception('App', 'uncaught', error, stack);
    return false;
  };
  await Catalog.instance.initialize(
    dataDirectory: scraperValidationDirectory,
    enableFoundation: experimentalScraping,
    enableTasks: experimentalScraping,
    enableMappings: experimentalScraping,
    enableRecognition: experimentalScraping,
    enableAutomaticRecognition: experimentalScraping,
    enableScopedArtwork: experimentalScraping,
    enableChapterRelations: experimentalScraping,
    enableLibraryMerge: experimentalScraping,
  );
  await ArtworkSettings.instance.load();
  await AppTheme.instance.load();
  await AppLanguage.instance.load();
  await WatchSettings.instance.load();
  try {
    await OptionalFeatures.instance.initialize();
  } catch (error, stack) {
    DebugLog.exception('OptionalFeatures', 'initialize_failed', error, stack);
  }
  await MpvConfigStore.instance.initialize();
  MediaKit.ensureInitialized();
  const secure = FlutterSecureStorage();
  await Metadata.loadCredentials((key) => secure.read(key: key));
  runApp(const CCPlayer());
  if (experimentalScraping) {
    ScrapeTaskRunner.forCatalog(Catalog.instance).startAutomaticQueue();
  }
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
  bool historySelected = false;
  bool get mobile => widget.mobile ?? !AppHeader.desktop;
  void _select(int index) {
    navigatorKey.currentState?.popUntil((route) => route.isFirst);
    setState(() {
      settingsSelected = index == 3;
      historySelected = index == 2;
    });
    if (index < 2) libraryDestination.value = index == 1;
  }

  Widget _navigation(KonataNavigationLayout layout) =>
      ValueListenableBuilder<bool>(
        valueListenable: libraryDestination,
        builder: (context, sources, _) =>
            ValueListenableBuilder<PlayingHeader?>(
              valueListenable: playingHeader,
              builder: (context, playback, _) => playback?.videoOverlay == true
                  ? const SizedBox.shrink()
                  : AppHeader(
                      playbackTitle: playback?.title,
                      onPlaybackBack: playback?.onBack,
                      showSources: sources,
                      mobile: mobile,
                      layout: layout,
                      settingsSelected: settingsSelected,
                      historySelected: historySelected,
                      onNavigate: (value) => _select(value ? 1 : 0),
                      onHistory: () => _select(2),
                      onSettings: () => _select(3),
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
              child: LayoutBuilder(
                builder: (context, bounds) {
                  if (fullscreen) return child!;
                  final layout = navigationLayout(
                    bounds.biggest,
                    desktop: !mobile,
                  );
                  if (layout == KonataNavigationLayout.rail) {
                    return Row(
                      children: [
                        _navigation(layout),
                        Expanded(child: child!),
                      ],
                    );
                  }
                  return Column(
                    children: [
                      if (layout == KonataNavigationLayout.top)
                        _navigation(layout),
                      Expanded(child: child!),
                      if (layout == KonataNavigationLayout.bottom)
                        _navigation(layout),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
      home: PopScope(
        canPop: !settingsSelected && !historySelected,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop) _select(0);
        },
        child: LayoutBuilder(
          builder: (context, bounds) => AnimatedSwitcher(
            key: const ValueKey('main-section-switcher'),
            duration: KonataMotion.duration(context),
            transitionBuilder: (child, animation) =>
                KonataMotion.sectionTransition(animation, child),
            layoutBuilder: KonataMotion.sectionLayout,
            child: settingsSelected
                ? SettingsPage(
                    key: ValueKey('settings'),
                    embedded: true,
                    wideLayout:
                        bounds.maxWidth >= 840 && bounds.maxHeight >= 500,
                  )
                : historySelected
                ? const PlaybackHistoryPage(
                    key: ValueKey('history'),
                    embedded: true,
                  )
                : LibraryPage(key: const ValueKey('library'), mobile: mobile),
          ),
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
  bool pendingReviewOnly = false;
  Set<String> sourceKinds = {...librarySourceKinds};
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
      final displayWorks = [
        for (final work in cat.works)
          if (cat.standaloneParts[work['id']] case final parts?)
            for (final part in parts)
              {
                ...work,
                ...part,
                'scoped_poster': part['poster'],
                'scoped_poster_empty': false,
                'poster_fallback': null,
              }
          else
            work,
      ];
      final pendingReviewCount = displayWorks
          .where((w) => w['needs_review'] == 1)
          .length;
      final matches = filterLibraryWorks(
        works: displayWorks,
        assets: cat.assets,
        sources: cat.sources,
        kinds: sourceKinds,
        query: filter,
        pendingReviewOnly: pendingReviewOnly,
      );
      return Scaffold(
        body: Column(
          children: [
            if (cat.scanning) const LinearProgressIndicator(),
            _libraryToolbar(cat, matches.length, pendingReviewCount),
            const Divider(height: 1),
            Expanded(
              child: AnimatedSwitcher(
                key: const ValueKey('library-source-switcher'),
                duration: KonataMotion.duration(context),
                transitionBuilder: (child, animation) =>
                    KonataMotion.sectionTransition(animation, child),
                layoutBuilder: KonataMotion.sectionLayout,
                child: KeyedSubtree(
                  key: ValueKey(showSources),
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
                            final horizontalPadding = bounds.maxWidth < 600
                                ? 20.0
                                : 32.0;
                            final crossSpacing = bounds.maxWidth < 600
                                ? 16.0
                                : 24.0;
                            const preferredPosterWidth = 220.0;
                            final available =
                                bounds.maxWidth - 2 * horizontalPadding;
                            final columns = available > 0
                                ? ((available + crossSpacing) /
                                          (preferredPosterWidth + crossSpacing))
                                      .ceil()
                                      .clamp(2, 12)
                                : 1;
                            final cardWidth =
                                (bounds.maxWidth -
                                    2 * horizontalPadding -
                                    (columns - 1) * crossSpacing) /
                                columns;
                            final cardHeight =
                                cardWidth * 1.5 + 8 + _posterTitleHeight;
                            return GridView.builder(
                              padding: EdgeInsets.all(horizontalPadding),
                              itemCount: matches.length,
                              gridDelegate:
                                  SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: columns,
                                    mainAxisExtent: cardHeight,
                                    crossAxisSpacing: crossSpacing,
                                    mainAxisSpacing: 24,
                                  ),
                              itemBuilder: (ctx, i) => _poster(matches[i]),
                            );
                          },
                        ),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
  Widget _libraryToolbar(Catalog cat, int count, int pendingReviewCount) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
        child: LayoutBuilder(
          builder: (context, bounds) {
            final compact = bounds.maxWidth < 500;
            final search = TextField(
              key: const ValueKey('library-search'),
              controller: searchController,
              decoration: InputDecoration(
                hintText: context.l10n.searchTitles,
                prefixIcon: const Icon(Icons.search, size: 19),
                suffixIcon: filter.isEmpty
                    ? null
                    : IconButton(
                        tooltip: context.l10n.closeSearch,
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () => setState(() {
                          searchController.clear();
                          filter = '';
                        }),
                      ),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(28),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(28),
                  borderSide: BorderSide.none,
                ),
              ),
              onChanged: (value) => setState(() => filter = value),
            );
            final hiddenWorksButton = cat.hiddenWorkEntries.isEmpty
                ? null
                : IconButton(
                    key: const ValueKey('manage-hidden-works-button'),
                    tooltip: context.l10n.manageHidden,
                    icon: const Icon(Icons.visibility_off_outlined),
                    onPressed: _manageHiddenWorks,
                  );
            return Row(
              key: const ValueKey('library-toolbar-row'),
              children: [
                if (!showSources && !(compact && searchOpen))
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: LibrarySourceFilter(
                        kinds: sourceKinds,
                        count: count,
                        onChanged: (value) =>
                            setState(() => sourceKinds = value),
                        pendingReviewOnly: pendingReviewOnly,
                        pendingReviewCount: pendingReviewCount,
                        onPendingReviewChanged: (value) =>
                            setState(() => pendingReviewOnly = value),
                      ),
                    ),
                  ),
                if (showSources)
                  Text(
                    context.l10n.sourceCount(cat.sources.length),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                if (!showSources) ...[
                  const SizedBox(width: 8),
                  SizedBox(
                    width: (bounds.maxWidth * .4).clamp(80.0, 300.0),
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 300),
                        child: search,
                      ),
                    ),
                  ),
                  if (hiddenWorksButton != null) hiddenWorksButton,
                ],
                if (showSources)
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Wrap(
                        alignment: WrapAlignment.end,
                        spacing: 8,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (hiddenWorksButton != null) hiddenWorksButton,
                          if (cat.taskStore != null)
                            OutlinedButton.icon(
                              onPressed: () => Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => ScrapeTasksPage(
                                    runner: ScrapeTaskRunner.forCatalog(cat),
                                  ),
                                ),
                              ),
                              icon: const Icon(Icons.rule_folder_outlined),
                              label: Text(
                                Localizations.localeOf(context).languageCode ==
                                        'zh'
                                    ? '刮削任务'
                                    : 'Scraping tasks',
                              ),
                            ),
                          FilledButton.icon(
                            onPressed: _add,
                            icon: const Icon(Icons.add, size: 20),
                            label: Text(context.l10n.addSource),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      );
  double get _posterTitleHeight =>
      MediaQuery.textScalerOf(context).scale(16) * 1.5 + 2;

  Widget _poster(Map<String, Object?> work) => InkWell(
    onTap: () => Navigator.push(
      context,
      PageRouteBuilder<void>(
        transitionDuration: KonataMotion.coverDuration(context),
        reverseTransitionDuration: KonataMotion.coverDuration(
          context,
          reverse: true,
        ),
        transitionsBuilder: (context, animation, secondary, child) =>
            KonataMotion.coverTransition(animation, child),
        pageBuilder: (_, animation, secondary) => WorkPage(
          workId: work['id'].toString(),
          partAssetId: work['asset_id'] as String?,
        ),
      ),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AspectRatio(
          key: ValueKey('library-poster-${work['asset_id'] ?? work['id']}'),
          aspectRatio: 2 / 3,
          child: KonataPoster(
            tag: 'work-poster-${work['asset_id'] ?? work['id']}',
            image: (alignment) => Catalog.preferredPoster(work) != null
                ? ManagedImage(
                    Catalog.preferredPoster(work)!,
                    owner: work['id'].toString(),
                    fit: BoxFit.cover,
                    alignment: alignment,
                    errorBuilder: (_, _, _) {
                      final fallback = work['poster_fallback']?.toString();
                      if (fallback == null ||
                          fallback.isEmpty ||
                          fallback == work['poster']) {
                        return _blankPoster();
                      }
                      return ManagedImage(
                        fallback,
                        owner: work['id'].toString(),
                        fit: BoxFit.cover,
                        alignment: alignment,
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
              key: ValueKey('library-title-${work['asset_id'] ?? work['id']}'),
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
      LayoutBuilder(
        builder: (context, bounds) {
          const gap = 12.0;
          // The card needs 420 px for inline actions, plus its inner padding.
          const minCardWidth = 456.0;
          final fit = ((bounds.maxWidth + gap) / (minCardWidth + gap)).floor();
          final columns = fit > 0 ? fit : 1;
          final cardWidth = (bounds.maxWidth - (columns - 1) * gap) / columns;
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (final source in cat.sources)
                SizedBox(width: cardWidth, child: _sourceCard(source)),
            ],
          );
        },
      ),
    ],
  );

  Widget _sourceCard(Map<String, Object?> source) => Card(
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
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: .55),
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
                  onPressed: () => SourceEditor.show(context, source),
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
                        content: Text(context.l10n.removeSourceBody),
                        actions: [
                          UniformActionBar(
                            children: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, false),
                                child: Text(context.l10n.cancel),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.pop(ctx, true),
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
                      Align(alignment: Alignment.centerRight, child: actions),
                    ],
                  );
          },
        ),
      ),
    ),
  );

  Future<void> _add() async {
    var kind = 'local';
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
                    ButtonTheme(
                      alignedDropdown: true,
                      child: DropdownButtonFormField<String>(
                        key: const ValueKey('source-type-selector'),
                        initialValue: kind,
                        isExpanded: true,
                        elevation: 2,
                        dropdownColor: Theme.of(ctx).colorScheme.surface,
                        borderRadius: BorderRadius.circular(12),
                        decoration: fieldDecoration(ctx.l10n.sourceLabel),
                        items: [
                          for (final option in [
                            (
                              'local',
                              ctx.l10n.localFolder,
                              Icons.folder_outlined,
                            ),
                            ('webdav', 'WebDAV', Icons.dns_outlined),
                            ('smb', 'SMB', Icons.storage_outlined),
                          ])
                            DropdownMenuItem(
                              value: option.$1,
                              child: Row(
                                children: [
                                  Icon(option.$3, size: 20),
                                  const SizedBox(width: 12),
                                  Text(option.$2),
                                ],
                              ),
                            ),
                        ],
                        onChanged: (value) {
                          if (value != null) update(() => kind = value);
                        },
                      ),
                    ),
                    const SizedBox(height: 20),
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
            androidOptions: const FilePickerAndroidOptions(
              safOptions: AndroidSAFOptions(grant: AndroidSAFGrant.lifetime),
            ),
          );
          if (!mounted) return;
          if (chosen != null && chosen.isNotEmpty) {
            final id = await Catalog.instance.addSource(
              'local',
              name.text.trim().isEmpty
                  ? LocalMedia.label(chosen)
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
  const WorkPage({super.key, required this.workId, this.partAssetId});
  final String workId;
  final String? partAssetId;
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
        return Scaffold(
          appBar: AppBar(),
          body: Center(child: Text(context.l10n.titleNotFound)),
        );
      }
      final work = found.first;
      final partId = widget.partAssetId;
      final part = cat.standaloneParts[widget.workId]
          ?.where((row) => row['asset_id'] == partId)
          .singleOrNull;
      if (partId != null && part == null) {
        return Scaffold(
          appBar: AppBar(),
          body: Center(child: Text(context.l10n.titleNotFound)),
        );
      }
      return NipaPlayDetailPage(
        work: work,
        standalonePart: part,
        assets: partId == null
            ? cat.forWork(widget.workId)
            : cat
                  .forWork(widget.workId)
                  .where((asset) => asset['id'] == partId)
                  .toList(),
        onEditMetadata: () => WorkEditDialogs.metadata(
          context,
          work,
          searchAndBind: () => _match(work),
        ),
        onEditPartMetadata: (binding) => WorkEditDialogs.metadata(
          context,
          work,
          partBinding: binding,
          searchAndBind: () => _match(work),
        ),
        onEditCover: () => WorkEditDialogs.cover(context, work),
        onEditBackdrop: (fallback) =>
            WorkEditDialogs.backdrop(context, work, fallbackBackdrop: fallback),
        onHide: () => _hideWork(work),
        onDelete: () => _deleteWork(work),
        onBack: () => Navigator.maybePop(context),
      );
    },
  );

  Future<void> _hideWork(Map<String, Object?> work) async {
    if (Catalog.instance.scanning) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.scanBeforeRemove)));
      return;
    }
    final title = work['title']?.toString() ?? '';
    var keepHidden = false;
    final confirmedKeepHidden = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, update) {
          final theme = Theme.of(dialogContext);
          return AlertDialog(
            title: Text(dialogContext.hideWorkAction),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (title.isNotEmpty) ...[
                      Text(
                        title,
                        style: theme.textTheme.titleSmall,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 8),
                    ],
                    Text(
                      dialogContext.hideWorkDescription,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    CheckboxListTile(
                      key: const ValueKey('keep-work-hidden-checkbox'),
                      value: keepHidden,
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text(dialogContext.l10n.keepHidden),
                      subtitle: Text(dialogContext.l10n.rescanRestoresHint),
                      onChanged: (value) =>
                          update(() => keepHidden = value ?? false),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              UniformActionBar(
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: Text(dialogContext.l10n.cancel),
                  ),
                  FilledButton.tonal(
                    key: const ValueKey('confirm-hide-work'),
                    onPressed: () => Navigator.pop(dialogContext, keepHidden),
                    child: Text(dialogContext.hideWorkAction),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
    if (confirmedKeepHidden == null || !mounted) return;
    try {
      await Catalog.instance.hideWork(
        widget.workId,
        keepHidden: confirmedKeepHidden,
      );
      if (mounted) await Navigator.maybePop(context);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.l10n.removeWorkFailed)));
      }
    }
  }

  Future<void> _deleteWork(Map<String, Object?> work) async {
    if (Catalog.instance.scanning) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.scanBeforeRemove)));
      return;
    }
    final title = work['title']?.toString() ?? '';
    final confirmedDelete = await showDialog<bool>(
      context: context,
      builder: (confirmContext) {
        final theme = Theme.of(confirmContext);
        return AlertDialog(
          title: Text(confirmContext.deleteWorkConfirmTitle),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (title.isNotEmpty) ...[
                    Text(
                      title,
                      style: theme.textTheme.titleSmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 10),
                  ],
                  Text(confirmContext.deleteWorkConfirmBody),
                ],
              ),
            ),
          ),
          actions: [
            UniformActionBar(
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(confirmContext, false),
                  child: Text(confirmContext.l10n.cancel),
                ),
                FilledButton(
                  key: const ValueKey('confirm-delete-work'),
                  style: FilledButton.styleFrom(
                    backgroundColor: theme.colorScheme.error,
                    foregroundColor: theme.colorScheme.onError,
                  ),
                  onPressed: () => Navigator.pop(confirmContext, true),
                  child: Text(confirmContext.confirmDeleteAction),
                ),
              ],
            ),
          ],
        );
      },
    );
    if (confirmedDelete != true || !mounted) return;
    try {
      await Catalog.instance.deleteWork(widget.workId);
      if (mounted) await Navigator.maybePop(context);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.l10n.removeWorkFailed)));
      }
    }
  }

  Future<void> _match(Map<String, Object?> work) =>
      showManualMatchDialog(context, work);
}

/// Shared TMDB/Bangumi manual search and bind dialog used by both WorkPage
/// and the in-place review workflow inside ScanProgressDialog.
Future<bool> showManualMatchDialog(
  BuildContext context,
  Map<String, Object?> work,
) async {
  final workId = work['id']?.toString() ?? '';
  final rawTitle = work['title']?.toString() ?? '';
  final query = TextEditingController(text: Catalog.cleanTitle(rawTitle));
  String provider = 'tmdb';
  bool loading = false;
  String? failure;
  List<Candidate> results = [];
  final route = DialogRoute<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, update) => AlertDialog(
        title: Text(ctx.l10n.manualMatch),
        content: SizedBox(
          width: 540,
          height: 490,
          child: ListView(
            padding: const EdgeInsets.only(right: 12, top: 8),
            children: [
              SegmentedButton<String>(
                key: const ValueKey('manual-match-provider'),
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 'tmdb', label: Text('TMDB')),
                  ButtonSegment(value: 'bangumi', label: Text('Bangumi')),
                ],
                selected: {provider},
                onSelectionChanged: loading
                    ? null
                    : (v) => update(() {
                        provider = v.first;
                        results = [];
                      }),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('manual-match-query'),
                      controller: query,
                      decoration: InputDecoration(
                        labelText: provider == 'tmdb'
                            ? ctx.l10n.nameOrId
                            : ctx.l10n.nameOrBangumiId,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  IconButton.filled(
                    key: const ValueKey('manual-match-search'),
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
              ...[
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
                                workId,
                                provider: result.provider,
                                providerId: result.id,
                                title: result.title,
                                year: result.year,
                                poster: result.poster,
                                overview: result.overview,
                                type: result.mediaType,
                              );
                              if (ctx.mounted) Navigator.pop(ctx, true);
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
            ],
          ),
        ),
        actions: [
          UniformActionBar(
            children: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(ctx.l10n.closeWindow),
              ),
            ],
          ),
        ],
      ),
    ),
  );
  final bound = await Navigator.of(context, rootNavigator: true).push<bool>(
    route,
  );
  await route.completed;
  query.dispose();
  return bound == true;
}
