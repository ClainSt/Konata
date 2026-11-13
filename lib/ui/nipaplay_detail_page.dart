import '../core/episode_metadata.dart';
import 'manual_episode_page.dart';
import '../l10n/strings.dart';
import 'managed_image.dart';
import '../core/artwork_settings.dart';
import 'optional_details.dart';
import 'media_version_picker.dart';
import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'konata_motion.dart';
import '../core/catalog.dart';
import '../core/detail_metadata.dart';
import '../core/scan_recognition.dart';
import '../core/scoped_artwork.dart';
import '../core/scrape_task_runner.dart';
import 'scoped_artwork_dialog.dart';
import 'chapter_relations_page.dart';
import '../core/episode_grouping.dart';
import '../core/cloud_media_asset_presentation.dart';
import 'nipaplay_style.dart';
import 'horizontal_rail.dart';
import '../core/app_language.dart';
import 'watch_page.dart';

/// CCPlayer adaptation of the NipaPlay Personal detail screen.
class NipaPlayDetailPage extends StatefulWidget {
  const NipaPlayDetailPage({
    super.key,
    required this.work,
    required this.assets,
    required this.onEditMetadata,
    required this.onEditCover,
    required this.onDelete,
    required this.onBack,
    this.onHide,
    this.onEditBackdrop,
    this.onEditPartMetadata,
    this.standalonePart,
  });
  final Map<String, Object?> work;
  final Map<String, Object?>? standalonePart;
  final List<Map<String, Object?>> assets;
  final VoidCallback onEditMetadata, onEditCover, onDelete, onBack;
  final VoidCallback? onHide;
  final Future<void> Function(String? currentBackdrop)? onEditBackdrop;
  final Future<void> Function(String binding)? onEditPartMetadata;
  @override
  State<NipaPlayDetailPage> createState() => _NipaPlayDetailPageState();
}

class _NipaPlayDetailPageState extends State<NipaPlayDetailPage> {
  Map<String, dynamic> details = {};
  Map<String, Map<String, Object?>> progress = {};
  bool expanded = false, expandedSummary = false;
  String section = 'main';
  String extraFilter = '全部';
  int generation = 0;
  int? backdropGeneration;
  int? synopsisIndex;
  String? _overviewLanguage;
  final _localizedOverviews = <(int, String, int?, String), String?>{};
  (int, int, int, String)? _specialTitleKey;
  Future<String?>? _specialTitle;
  final rail = ScrollController();

  @override
  void initState() {
    super.initState();
    ArtworkSettings.instance.addListener(_artworkChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    Localizations.localeOf(context);
    final language = AppLanguage.instance.metadataLanguage;
    if (_overviewLanguage == language) return;
    _overviewLanguage = language;
    refresh();
  }

  @override
  void didUpdateWidget(covariant NipaPlayDetailPage old) {
    super.didUpdateWidget(old);
    if (Catalog.detailIdentity(old.work) !=
            Catalog.detailIdentity(widget.work) ||
        (Catalog.instance.recognitionEnabled && old.work != widget.work) ||
        old.work['id'] != widget.work['id'] ||
        old.assets
                .map(
                  (a) =>
                      '${a['id']}:${a['season']}:${a['episode']}:${a['category']}',
                )
                .join('|') !=
            widget.assets
                .map(
                  (a) =>
                      '${a['id']}:${a['season']}:${a['episode']}:${a['category']}',
                )
                .join('|')) {
      details = {};
      refresh();
    }
  }

  @override
  void dispose() {
    ArtworkSettings.instance.removeListener(_artworkChanged);
    generation++;
    rail.dispose();
    super.dispose();
  }

  void _artworkChanged() {
    if (mounted) setState(() {});
  }

  Future<void> refresh({bool force = false}) async {
    final seq = ++generation;
    final cat = Catalog.instance;
    final recognized = await ScanRecognition.details(cat, widget.work);
    if (!mounted || seq != generation) return;
    if (recognized != null) {
      final records = await cat.progressForWork(widget.work['id'].toString());
      if (!mounted || seq != generation) return;
      setState(() {
        progress = records;
        details = recognized;
        if (widget.standalonePart case final part?) {
          details['recognized_title'] = part['title'];
          details['overview'] = AppLanguage.bangumiSynopsis(
            part['summary'],
            _overviewLanguage ?? 'zh-CN',
          );
          details.remove('recognized_synopses');
          final files = details['recognized_file_details'] as Map;
          final file = files[part['asset_id']] as Map?;
          if (file != null && (_overviewLanguage ?? 'zh-CN').startsWith('zh')) {
            file['name'] = part['title'];
          }
        }
      });
      if (recognized['recognized_movie_tmdb'] case final int movieId
          when recognized['movieStill'] == null) {
        unawaited(_loadMovieStill(movieId, seq));
      }
      unawaited(_refreshStandaloneTitle(seq));
      if (widget.standalonePart == null && cat.scopedArtworkEnabled) {
        await _scopedImage(ScopedImage.poster, seq);
      }
      if (mounted && seq == generation) {
        await _refreshLocalizedOverviews(seq);
        await _refreshBangumiParts(seq);
      }
      return;
    }
    final cached = await cat.readWorkDetails(widget.work);
    final records = await cat.progressForWork(widget.work['id'].toString());
    if (!mounted || seq != generation) return;
    setState(() {
      progress = records;
      if (cached != null) {
        details = Map<String, dynamic>.from(cached);
        if (cached['overview_language'] != _overviewLanguage)
          details.remove('overview');
        if ((cached['schemaVersion'] as int? ?? 0) < 6 &&
            widget.work['tmdb_type'] == 'movie') {
          details['tags'] = (details['tags'] as List? ?? [])
              .where((tag) => tag != '剧场版')
              .toList();
        }
      }
    });
    final fetched = await cat.detailFetchedAt(widget.work['id'].toString());
    if (!force &&
        cached != null &&
        fetched != null &&
        DateTime.now().difference(fetched) < const Duration(days: 3) &&
        (cached['schemaVersion'] as int? ?? 0) >=
            DetailMetadataService.schemaVersion &&
        cached['overview_language'] == _overviewLanguage) {
      return;
    }
    if (widget.work['tmdb_id'] == null && widget.work['bangumi_id'] == null) {
      return;
    }
    final svc = DetailMetadataService();
    try {
      final fresh = await svc.fetch(widget.work, assets: widget.assets);
      if (!mounted || seq != generation) return;
      final merged = Map<String, dynamic>.from(details);
      for (final entry in fresh.entries) {
        final value = entry.value;
        if (value == null ||
            (value is String && value.isEmpty) ||
            (value is List && value.isEmpty && merged.containsKey(entry.key)) ||
            (value is Map && value.isEmpty && merged.containsKey(entry.key))) {
          continue;
        }
        merged[entry.key] = value;
      }
      await cat.saveWorkDetails(widget.work, merged);
      if (mounted && seq == generation) setState(() => details = merged);
    } catch (_) {
      /* Preserve cached metadata when providers fail. */
    } finally {
      svc.close();
    }
  }

  Future<void> _loadMovieStill(int movieId, int seq) async {
    final service = DetailMetadataService();
    try {
      final still = await service.fetchMovieStill(movieId);
      if (mounted && seq == generation && still != null) {
        setState(() => details['movieStill'] = still);
      }
    } catch (_) {
      // The work remains playable when artwork is unavailable.
    } finally {
      service.close();
    }
  }

  Future<void> _refreshBangumiParts(int seq) async {
    final parts = (details['recognized_synopses'] as List?)
        ?.whereType<Map>()
        .toList();
    if (parts == null || parts.isEmpty) return;
    final service = DetailMetadataService();
    try {
      if (parts.length == 1 &&
          parts.single['bangumi_subject'] is int &&
          details['recognized_split_dates'] is List) {
        final resolved = await service.bangumiSplitParts(
          parts.single['bangumi_subject'] as int,
          (details['recognized_split_dates'] as List).cast<String>(),
          _overviewLanguage ?? 'zh-CN',
        );
        if (mounted && seq == generation && resolved.length == 2) {
          setState(
            () => details['recognized_synopses'] = [
              {...parts.single, ...resolved.first},
              resolved.last,
            ],
          );
        }
        return;
      }
      if (parts.length < 2) return;
      final resolved = await Future.wait(
        parts.map((part) async {
          final id = part['bangumi_subject'];
          if (id is! int || (part['label'] != null && part['poster'] != null))
            return part;
          try {
            return {
              ...part,
              ...await service.bangumiPart(id, _overviewLanguage ?? 'zh-CN'),
            };
          } catch (_) {
            return part;
          }
        }),
      );
      if (mounted && seq == generation) {
        setState(() => details['recognized_synopses'] = resolved);
      }
    } catch (_) {
      // Keep the confirmed subject if the sequel cannot be verified.
    } finally {
      service.close();
    }
  }

  Future<void> _refreshStandaloneTitle(int seq) async {
    final asset = widget.assets
        .where((asset) => asset['category'] == 'main')
        .singleOrNull;
    if (asset == null) return;
    final assetId = asset['id'];
    final file = (details['recognized_file_details'] as Map)[assetId] as Map?;
    final series = details['recognized_tmdb_id'];
    final episode = file?['special_number'],
        chapter = file?['localized_special_chapter'];
    if (series is! int || episode is! int || chapter is! int) return;
    final language = _overviewLanguage ?? 'zh-CN';
    final key = (series, episode, chapter, language);
    if (_specialTitleKey != key) {
      _specialTitleKey = key;
      _specialTitle = () async {
        final service = DetailMetadataService();
        try {
          return await service.localizedSpecialTitle(
            series,
            episode,
            chapter,
            language,
          );
        } catch (_) {
          return null;
        } finally {
          service.close();
        }
      }();
    }
    final title = await _specialTitle;
    if (!mounted || seq != generation || title == null) return;
    final current =
        (details['recognized_file_details'] as Map)[assetId] as Map?;
    if (current != null) setState(() => current['name'] = title);
  }

  Future<void> _refreshLocalizedOverviews(int seq) async {
    final language = _overviewLanguage;
    final parts = (details['recognized_synopses'] as List?)
        ?.whereType<Map>()
        .toList();
    if (language == null ||
        parts == null ||
        !parts.any((part) => part['overview_target'] is Map))
      return;
    final service = DetailMetadataService();
    try {
      final resolved = <Map>[];
      for (final part in parts) {
        if (!mounted || seq != generation) return;
        final target = part['overview_target'];
        if (target is! Map) {
          resolved.add(part);
          continue;
        }
        final key = (
          target['id'] as int,
          target['type'] as String,
          target['season'] as int?,
          language,
        );
        try {
          if (!_localizedOverviews.containsKey(key)) {
            _localizedOverviews[key] = await service.localizedTmdbOverview(
              key.$1,
              key.$2,
              key.$3,
              language,
            );
          }
        } catch (_) {
          // A missing translation or network failure does not affect bindings.
        }
        resolved.add({...part, 'summary': _localizedOverviews[key]});
      }
      if (mounted && seq == generation)
        setState(() {
          details['recognized_synopses'] = resolved;
          if (details['recognized_overview_mode'] == 'auto') {
            details['overview'] = resolved.firstOrNull?['summary'];
          }
        });
    } finally {
      service.close();
    }
  }

  Future<void> _scopedImage(ScopedImage kind, int seq) async {
    final catalog = Catalog.instance;
    final runner = ScrapeTaskRunner.forCatalog(catalog);
    final work = widget.work['id'] as String;
    final field = kind == ScopedImage.poster ? 'poster' : 'backdrop';
    try {
      final choice = await runner.artwork.review(work, kind);
      if (!mounted || seq != generation || choice == null) return;
      final current = (choice['selected'] as Map?)?['url'];
      setState(() {
        details[field] = current;
        details['${field}_explicit'] =
            choice['state'] == 'empty' || choice['state'] == 'manual';
      });
      if (kind == ScopedImage.poster && widget.work['manual_cover_url'] != null)
        return;
      final job = await runner.artwork.enqueue(work, kind);
      if (job == null || !mounted || seq != generation) return;
      await runner.run(job);
      final url = await runner.artwork.displayed(work, kind);
      if (mounted && seq == generation) setState(() => details[field] = url);
    } catch (_) {
      // Existing metadata and user artwork remain available.
    }
  }

  Future<void> _editScopedDetails(String action) async {
    final work = widget.work['id'] as String;
    try {
      final updated = action == 'restore-fields'
          ? await restoreScopedField(context, work)
          : await editScopedArtwork(context, work, switch (action) {
              'scoped-cover' => ScopedImage.poster,
              _ => ScopedImage.backdrop,
            });
      if (mounted && updated) await refresh();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              Localizations.localeOf(context).languageCode == 'zh'
                  ? '资料或图片暂时无法更新，已保留当前选择'
                  : 'Could not update. The current selection is retained.',
            ),
          ),
        );
      }
    }
  }

  Future<void> _editMetadata() async {
    final parts = (details['recognized_synopses'] as List?) ?? const [];
    final index = synopsisIndex;
    final binding = index != null && index < parts.length
        ? parts[index]['binding']
        : null;
    if (binding is! String || widget.onEditPartMetadata == null) {
      widget.onEditMetadata();
      return;
    }
    try {
      await widget.onEditPartMetadata!(binding);
      if (mounted) await refresh();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              Localizations.localeOf(context).languageCode == 'zh'
                  ? '此部分的绑定或资料已变化，请重新打开。'
                  : 'The part changed. Reopen the editor.',
            ),
          ),
        );
      }
    }
  }

  bool get hasTelevisionInventory =>
      !isMovie &&
      widget.standalonePart == null &&
      widget.assets.any(
        (file) =>
            file['category'] == 'main' && ((file['episode'] as num?) ?? 0) > 0,
      ) &&
      (details['recognized_tmdb_type'] == 'tv' ||
          widget.work['tmdb_type'] == 'tv');

  bool _independentMovie(Map<String, Object?> file) =>
      hasTelevisionInventory &&
      CloudMediaAssetPresentation.isIndependentMovie(file);

  String get filmsLabel =>
      Localizations.localeOf(context).languageCode == 'zh' ? '电影' : 'Films';

  List<EpisodeGroup> get episodeGroups => EpisodeGrouping.main(
    widget.assets.where((file) => !_independentMovie(file)).toList(),
  );
  List<Map<String, Object?>> get episodes =>
      episodeGroups.map((g) => g.preferred(progress)).toList();
  List<Map<String, Object?>> get allExtras {
    final files = widget.assets.where((a) => a['category'] == 'extra').toList();
    files.sort((a, b) {
      final first = EpisodeMetadata.isOva(extraType(a));
      final second = EpisodeMetadata.isOva(extraType(b));
      if (first != second) return first ? -1 : 1;
      final an = _extraNumber(a), bn = _extraNumber(b);
      if (an != bn) {
        if (an == null) return 1;
        if (bn == null) return -1;
        return an.compareTo(bn);
      }
      return '${a['name']}'.compareTo('${b['name']}');
    });
    return files;
  }

  int? _extraNumber(Map<String, Object?> asset) =>
      episodeInfo(asset)['special_number'] as int? ?? asset['episode'] as int?;

  String extraType(Map<String, Object?> asset) {
    final type = EpisodeMetadata.specialType(episodeInfo(asset)['name']);
    if (type != null) return type;
    final stored = asset['extra_type']?.toString();
    return stored?.isNotEmpty == true
        ? stored!
        : CloudMediaAssetPresentation.extraType(asset);
  }

  bool get isMovie =>
      details['recognized_movie'] == true ||
      widget.work['tmdb_type'] == 'movie';
  List<Map<String, Object?>> variantsFor(Map<String, Object?> asset) {
    final id = asset['id']?.toString();
    for (final group in episodeGroups) {
      if (group.versions.any((e) => e['id']?.toString() == id)) {
        return group.versions;
      }
    }
    return [asset];
  }

  Map<String, dynamic> episodeInfo(Map<String, Object?> asset) {
    if (_independentMovie(asset)) return {};
    final scoped = details['recognized_file_details'];
    final info = scoped is Map
        ? Map<String, dynamic>.from(scoped[asset['id']] as Map? ?? {})
        : EpisodeMetadata.lookup(widget.work, details, asset);
    if (isMovie && asset['category'] == 'main') {
      if (info['blank_still'] != true &&
          info['still']?.toString().trim().isNotEmpty != true) {
        info['still'] = details['movieStill'];
      }
      info['name'] ??= details['recognized_title'] ?? widget.work['title'];
    }
    return info;
  }

  String episodeLabel(Map<String, Object?> asset) {
    if (_independentMovie(asset)) return filmsLabel;
    final n = asset['episode'];
    if (asset['category'] == 'extra') {
      final type = extraType(asset);
      if (EpisodeMetadata.isOva(type)) return type;
    }
    return asset['category'] == 'extra'
        ? (extraType(asset) == '其他'
                  ? context.l10n.otherExtra
                  : extraType(asset)) +
              (n == null ? '' : ' $n')
        : (n == null
              ? context.l10n.mainFeature
              : context.l10n.episodeLabel((n as num).toInt()));
  }

  String episodeTitle(Map<String, Object?> asset) {
    final metadataTitle = episodeInfo(asset)['name']?.toString().trim();
    if (metadataTitle?.isNotEmpty == true) {
      if (asset['category'] != 'extra' ||
          !EpisodeMetadata.isOva(extraType(asset))) {
        return metadataTitle!;
      }
      final title = EpisodeMetadata.specialTitle(metadataTitle!);
      if (title.isNotEmpty) return title;
    }
    if (asset['category'] == 'extra') {
      final label = extraCoverLabel(asset);
      final names = {
        'CM': context.l10n.commercial,
        'PV': context.l10n.promoVideo,
        'NCOP': context.l10n.cleanOpening,
        'NCED': context.l10n.cleanEnding,
        'MENU': context.l10n.discMenu,
        'SP': context.l10n.specialEpisode,
        'OVA': 'OVA',
        'OAD': 'OAD',
      };
      final type = extraType(asset);
      if (type == '其他') {
        final cleaned = CloudMediaAssetPresentation.cleanedExtraFilename(asset);
        if (cleaned.isNotEmpty) return cleaned;
        final name = asset['name']?.toString().trim();
        if (name != null && name.isNotEmpty) return name;
        final path = asset['relative_path']?.toString().replaceAll('\\', '/');
        return path
                ?.split('/')
                .lastWhere(
                  (part) => part.isNotEmpty,
                  orElse: () => context.l10n.unnamedVideo,
                ) ??
            context.l10n.unnamedVideo;
      }
      final number = RegExp(r'\d+[A-Za-z]?$').firstMatch(label)?.group(0);
      return '${names[type] ?? type}${number == null ? '' : ' $number'}';
    }
    return asset['episode'] == null
        ? asset['name'].toString()
        : episodeLabel(asset);
  }

  double fraction(Map<String, Object?> asset) {
    final row = progress[asset['id']?.toString()];
    final pos = row?['position_ms'] as int? ?? 0;
    final total = row?['duration_ms'] as int? ?? 0;
    return total > 0 ? (pos / total).clamp(0.0, 1.0) : 0;
  }

  Map<String, Object?>? get resume {
    final candidates = episodes
        .where((a) => fraction(a) > 0 && fraction(a) < .95)
        .toList();
    candidates.sort((a, b) {
      final at = progress[a['id']?.toString()]?['updated_at']?.toString() ?? '';
      final bt = progress[b['id']?.toString()]?['updated_at']?.toString() ?? '';
      return bt.compareTo(at);
    });
    return candidates.isNotEmpty
        ? candidates.first
        : episodes.isEmpty
        ? null
        : episodes.first;
  }

  Future<void> play(
    Map<String, Object?> asset, {
    bool offerVersions = true,
  }) async {
    if (offerVersions) {
      final choices = variantsFor(asset);
      if (choices.length > 1) {
        final chosen = await MediaVersionPicker.choose(
          context,
          choices,
          sourceLabels: {
            for (final source in Catalog.instance.sources)
              source['id'].toString():
                  source['label']?.toString() ?? context.l10n.unnamedSource,
          },
        );
        if (chosen == null || !mounted) return;
        asset = chosen;
      }
    }
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => WatchPage(asset: asset)),
    );
    if (mounted) await refresh();
  }

  Widget image(
    String? url, {
    Alignment alignment = Alignment.center,
    String? fallbackUrl,
    ManagedArtwork artwork = ManagedArtwork.poster,
  }) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    if (url == null || url.isEmpty) {
      if (fallbackUrl != null && fallbackUrl.isNotEmpty) {
        return image(fallbackUrl, alignment: alignment);
      }
      return ColoredBox(
        color: dark ? const Color(0xff333333) : const Color(0xffeeeeee),
        child: const Center(
          child: Icon(Icons.movie_outlined, size: 34, color: Colors.grey),
        ),
      );
    }
    return ManagedImage(
      url,
      owner: widget.work['id'].toString(),
      artwork: artwork,
      fit: BoxFit.cover,
      alignment: alignment,
      errorBuilder: (_, _, _) {
        if (fallbackUrl != null &&
            fallbackUrl.isNotEmpty &&
            fallbackUrl != url) {
          return image(fallbackUrl, alignment: alignment);
        }
        return ColoredBox(
          color: Colors.black.withValues(alpha: .06),
          child: const Center(
            child: Icon(Icons.movie_outlined, color: Colors.grey),
          ),
        );
      },
    );
  }

  Widget coverImage(
    String? url, {
    Alignment alignment = Alignment.center,
    String? fallbackUrl,
    double radius = 8,
    Gradient? gradient,
  }) => KonataPoster(
    tag:
        'work-poster-${widget.standalonePart?['asset_id'] ?? widget.work['id']}',
    alignment: alignment,
    radius: radius,
    gradient: gradient,
    image: (alignment) =>
        image(url, alignment: alignment, fallbackUrl: fallbackUrl),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context), dark = theme.brightness == Brightness.dark;
    final text = theme.colorScheme.onSurface;
    final secondary = text.withValues(alpha: .7),
        muted = text.withValues(alpha: .55);
    final surface = theme.scaffoldBackgroundColor;
    final title =
        details['recognized_title']?.toString() ??
        widget.work['title']?.toString() ??
        context.l10n.unnamedWork;
    final posterFallback = widget.work['poster_fallback']?.toString();
    final scoped =
        Catalog.instance.scopedArtworkEnabled &&
        details['recognized_work'] != null;
    final synopses = (details['recognized_synopses'] as List?) ?? const [];
    final selectedSynopsis = synopsisIndex ?? (synopses.length > 1 ? 0 : -1);
    final part = selectedSynopsis < 0 || selectedSynopsis >= synopses.length
        ? null
        : synopses[selectedSynopsis];
    final poster =
        widget.standalonePart?['poster']?.toString() ??
        part?['poster']?.toString() ??
        (scoped &&
                (details['poster_explicit'] == true ||
                    details['poster'] != null)
            ? details['poster']?.toString()
            : Catalog.preferredPoster(widget.work) ??
                  details['poster']?.toString());
    final providerBackdrop = details['backdrop']?.toString().isNotEmpty == true
        ? details['backdrop']?.toString()
        : scoped
        ? null
        : poster;
    final backdrop = scoped
        ? providerBackdrop
        : Catalog.preferredBackdrop(widget.work, providerBackdrop);
    final rawOverview = widget.work['overview']?.toString().trim();
    final overviewMode = details['recognized_overview_mode'];
    final overview = part != null
        ? (part['summary'] as String? ?? '')
        : overviewMode == 'manual' || overviewMode == 'empty'
        ? rawOverview ?? ''
        : scoped
        ? details['overview']?.toString() ?? ''
        : widget.work['manual_lock'] == 1 || details['overview'] == null
        ? rawOverview ?? ''
        : details['overview']?.toString() ?? '';
    final tags = (details['tags'] as List? ?? [])
        .map((e) => e.toString())
        .toList();
    final extraFiles = allExtras;
    final movies = widget.assets.where(_independentMovie).toList();
    final kinds = extraFiles.map(extraType).toSet();
    final typeNames = [
      for (final type in ['OVA', 'OAD'])
        if (kinds.remove(type)) type,
      ...(kinds.toList()..sort()),
    ];
    final selected = switch (section) {
      'movies' when movies.isNotEmpty => movies,
      'extra' =>
        extraFiles
            .where((a) => extraFilter == '全部' || extraType(a) == extraFilter)
            .toList(),
      _ => episodes,
    };
    return Scaffold(
      backgroundColor: surface,
      body: LayoutBuilder(
        builder: (ctx, size) {
          final wide = size.maxWidth >= 650, desktop = size.maxWidth >= 1100;
          if (scoped &&
              wide &&
              size.maxHeight >= 500 &&
              ArtworkSettings.instance.backdrop &&
              backdropGeneration != generation) {
            final seq = backdropGeneration = generation;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && seq == generation)
                unawaited(_scopedImage(ScopedImage.backdrop, seq));
            });
          }
          final backdropSpaceAvailable =
              ArtworkSettings.instance.backdrop &&
              wide &&
              size.maxHeight >= 500;
          final showBackdrop = backdropSpaceAvailable && backdrop != null;
          final portraitCover =
              !wide && size.maxHeight > size.maxWidth && poster != null;
          final inset = desktop
              ? 40.0
              : wide
              ? 28.0
              : 16.0;
          final width = (size.maxWidth - inset * 2).clamp(0.0, size.maxWidth);
          final posterWidth = wide
              ? (desktop ? 245.0 : 170.0)
              : (width * .66).clamp(170.0, 310.0);
          return Stack(
            fit: StackFit.expand,
            children: [
              if (showBackdrop) ...[
                Positioned.fill(
                  key: const ValueKey('detail-backdrop'),
                  child: image(
                    backdrop,
                    artwork: ManagedArtwork.backdrop,
                    alignment: Alignment.topCenter,
                    fallbackUrl: scoped ? null : posterFallback,
                  ),
                ),
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        stops: const [0, .58, 1],
                        colors: [
                          surface.withValues(alpha: dark ? .8 : .72),
                          surface.withValues(alpha: .91),
                          surface,
                        ],
                      ),
                    ),
                  ),
                ),
              ],
              SafeArea(
                top: !portraitCover,
                child: ScrollConfiguration(
                  behavior: const _MouseScroll().copyWith(
                    scrollbars: size.maxWidth >= 650,
                  ),
                  child: SingleChildScrollView(
                    key: const ValueKey('detail-content-scroll'),
                    child: Column(
                      children: [
                        if (portraitCover)
                          SizedBox(
                            key: const ValueKey('detail-portrait-cover'),
                            width: double.infinity,
                            height: (size.maxWidth * 1.45).clamp(
                              0.0,
                              size.maxHeight * .65,
                            ),
                            child: coverImage(
                              poster,
                              alignment: Alignment.topCenter,
                              fallbackUrl: posterFallback,
                              radius: 0,
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                stops: const [0, .58, 1],
                                colors: [
                                  Colors.black26,
                                  surface.withAlpha(0),
                                  surface,
                                ],
                              ),
                            ),
                          ),
                        Padding(
                          padding: EdgeInsets.fromLTRB(
                            inset,
                            portraitCover ? 0 : 80,
                            inset,
                            48,
                          ),
                          child: Center(
                            child: ConstrainedBox(
                              constraints: BoxConstraints(maxWidth: width),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (wide)
                                    Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        SizedBox(
                                          width: posterWidth,
                                          height: posterWidth * 1.5,
                                          child: ClipRRect(
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                            child: coverImage(
                                              poster,
                                              fallbackUrl: posterFallback,
                                            ),
                                          ),
                                        ),
                                        SizedBox(width: desktop ? 32 : 20),
                                        Expanded(
                                          child: information(
                                            title,
                                            overview,
                                            details['score'],
                                            tags,
                                            secondary,
                                            muted,
                                            desktop,
                                          ),
                                        ),
                                      ],
                                    )
                                  else ...[
                                    if (!portraitCover) ...[
                                      Center(
                                        child: SizedBox(
                                          width: posterWidth,
                                          height: posterWidth * 1.5,
                                          child: ClipRRect(
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                            child: coverImage(
                                              poster,
                                              fallbackUrl: posterFallback,
                                            ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 20),
                                    ],
                                    information(
                                      title,
                                      overview,
                                      details['score'],
                                      tags,
                                      secondary,
                                      muted,
                                      false,
                                      fullWidthPlay: portraitCover,
                                    ),
                                  ],
                                  OptionalDetails(
                                    legacyCredits: {
                                      'cast': (details['cast'] as List? ?? [])
                                          .whereType<Map>()
                                          .toList(),
                                      'crew': (details['crew'] as List? ?? [])
                                          .whereType<Map>()
                                          .toList(),
                                    },
                                    legacyCharacters:
                                        (details['characters'] as List? ?? [])
                                            .whereType<Map>()
                                            .toList(),
                                    work: {
                                      ...widget.work,
                                      ...?(details['recognized_people']
                                          as Map<String, Object?>?),
                                      'original_language':
                                          details['original_language'],
                                      'origin_country':
                                          details['origin_country'],
                                      'origin_tags': details['origin_tags'],
                                      if (details['isAnimation'] is bool)
                                        'is_animation':
                                            details['isAnimation'] == true
                                            ? 1
                                            : 0,
                                      if (details['automaticBangumiId'] is int)
                                        'bangumi_id':
                                            details['automaticBangumiId'],
                                    },
                                  ),
                                  const SizedBox(height: 30),
                                  Wrap(
                                    alignment: WrapAlignment.spaceBetween,
                                    crossAxisAlignment:
                                        WrapCrossAlignment.center,
                                    spacing: 16,
                                    runSpacing: 8,
                                    children: [
                                      SingleChildScrollView(
                                        key: const ValueKey(
                                          'detail-section-tabs',
                                        ),
                                        scrollDirection: Axis.horizontal,
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            sectionTab(
                                              'main',
                                              context.l10n.mainFeature,
                                              episodes.length,
                                              muted,
                                            ),
                                            if (movies.isNotEmpty) ...[
                                              const SizedBox(width: 22),
                                              sectionTab(
                                                'movies',
                                                filmsLabel,
                                                movies.length,
                                                muted,
                                              ),
                                            ],
                                            const SizedBox(width: 22),
                                            sectionTab(
                                              'extra',
                                              context.l10n.extraFiles,
                                              extraFiles.length,
                                              muted,
                                            ),
                                          ],
                                        ),
                                      ),
                                      TextButton.icon(
                                        onPressed: () => setState(
                                          () => expanded = !expanded,
                                        ),
                                        icon: Icon(
                                          expanded
                                              ? Icons.view_carousel_outlined
                                              : Icons.view_list_outlined,
                                          size: 18,
                                        ),
                                        label: Text(
                                          expanded
                                              ? context.l10n.collapseList
                                              : context.l10n.fullList,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 12),
                                  if (section == 'extra' &&
                                      typeNames.isNotEmpty)
                                    Padding(
                                      padding: const EdgeInsets.only(
                                        bottom: 16,
                                      ),
                                      child: Wrap(
                                        spacing: 8,
                                        runSpacing: 8,
                                        children: [
                                          for (final type in [
                                            '全部',
                                            ...typeNames,
                                          ])
                                            ChoiceChip(
                                              label: Text(
                                                type == '全部'
                                                    ? context.l10n.allExtras
                                                    : type == '其他'
                                                    ? context.l10n.otherExtra
                                                    : type,
                                              ),
                                              selected: extraFilter == type,
                                              selectedColor:
                                                  NipaPlayStyle.accent,
                                              checkmarkColor:
                                                  NipaPlayStyle.onAccent,
                                              labelStyle: TextStyle(
                                                color: extraFilter == type
                                                    ? NipaPlayStyle.onAccent
                                                    : text,
                                                fontWeight: extraFilter == type
                                                    ? FontWeight.w600
                                                    : FontWeight.w400,
                                              ),
                                              onSelected: (_) => setState(
                                                () => extraFilter = type,
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  if (selected.isEmpty)
                                    Padding(
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 30,
                                      ),
                                      child: Text(
                                        section == 'extra'
                                            ? context.l10n.noExtras
                                            : context.l10n.noLinkedEpisodes,
                                        style: TextStyle(color: muted),
                                      ),
                                    )
                                  else if (expanded)
                                    LayoutBuilder(
                                      builder: (ctx, layout) {
                                        final count = layout.maxWidth > 0
                                            ? ((layout.maxWidth + 12) / 252)
                                                  .ceil()
                                            : 1;
                                        final tileWidth =
                                            (layout.maxWidth -
                                                12 * (count - 1)) /
                                            count;
                                        return Wrap(
                                          spacing: 12,
                                          runSpacing: 18,
                                          children: [
                                            for (final asset in selected)
                                              SizedBox(
                                                width: tileWidth,
                                                child: episodeTile(
                                                  asset,
                                                  secondary,
                                                ),
                                              ),
                                          ],
                                        );
                                      },
                                    )
                                  else
                                    HorizontalRail(
                                      controller: rail,
                                      itemWidth: 260,
                                      height:
                                          160 +
                                          MediaQuery.textScalerOf(
                                            context,
                                          ).scale(24),
                                      itemCount: selected.length,
                                      itemBuilder: (ctx, i) =>
                                          episodeTile(selected[i], secondary),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // Keep navigation and the more-actions menu accessible while
              // the poster, description and episodes scroll underneath.
              if (portraitCover)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: MediaQuery.paddingOf(context).top + 100,
                  child: const IgnorePointer(
                    child: DecoratedBox(
                      key: ValueKey('detail-navigation-scrim'),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.black54,
                            Colors.black38,
                            Colors.transparent,
                          ],
                          stops: [0, .65, 1],
                        ),
                      ),
                    ),
                  ),
                ),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: SafeArea(
                  bottom: false,
                  child: Container(
                    key: const ValueKey('detail-fixed-toolbar'),
                    height: 64,
                    // The page artwork already has a readability scrim.
                    // Keep this overlay clear so it remains one continuous canvas.
                    color: Colors.transparent,
                    child: Center(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: width),
                        child: Row(
                          children: [
                            IconButton(
                              key: const ValueKey('detail-back-button'),
                              tooltip: context.l10n.backToLibrary,
                              onPressed: widget.onBack,
                              style: IconButton.styleFrom(
                                backgroundColor: portraitCover
                                    ? Colors.transparent
                                    : surface.withValues(alpha: .7),
                              ),
                              icon: Icon(
                                Icons.arrow_back,
                                color: portraitCover ? Colors.white : text,
                                shadows: portraitCover
                                    ? const [
                                        Shadow(
                                          color: Colors.black87,
                                          blurRadius: 4,
                                          offset: Offset(0, 1),
                                        ),
                                      ]
                                    : null,
                              ),
                            ),
                            const Spacer(),
                            if (widget.standalonePart == null)
                              PopupMenuButton<String>(
                                key: const ValueKey('detail-more-button'),
                                tooltip: context.l10n.moreActions,
                                style: IconButton.styleFrom(
                                  backgroundColor: portraitCover
                                      ? Colors.transparent
                                      : surface.withValues(alpha: .7),
                                ),
                                icon: Icon(
                                  Icons.more_horiz,
                                  color: portraitCover ? Colors.white : text,
                                  shadows: portraitCover
                                      ? const [
                                          Shadow(
                                            color: Colors.black87,
                                            blurRadius: 4,
                                            offset: Offset(0, 1),
                                          ),
                                        ]
                                      : null,
                                ),
                                onSelected: (value) {
                                  if (value == 'metadata') {
                                    unawaited(_editMetadata());
                                  }
                                  if (value == 'manual') {
                                    Navigator.of(context).push(
                                      MaterialPageRoute<void>(
                                        builder: (_) => ManualEpisodePage(
                                          work: widget.work,
                                          assets: widget.assets,
                                        ),
                                      ),
                                    );
                                  }
                                  if (value == 'cover') {
                                    if (scoped &&
                                        (details['recognized_work'] as int? ??
                                                0) >
                                            0) {
                                      unawaited(
                                        _editScopedDetails('scoped-cover'),
                                      );
                                    } else {
                                      widget.onEditCover();
                                    }
                                  }
                                  if (value == 'backdrop') {
                                    if (scoped &&
                                        (details['recognized_work'] as int? ??
                                                0) >
                                            0) {
                                      unawaited(
                                        _editScopedDetails('scoped-backdrop'),
                                      );
                                    } else if (widget.onEditBackdrop != null) {
                                      unawaited(
                                        widget.onEditBackdrop!(
                                          providerBackdrop,
                                        ),
                                      );
                                    }
                                  }
                                  if (value == 'chapter-relations') {
                                    Navigator.of(context).push(
                                      MaterialPageRoute<void>(
                                        builder: (_) => ChapterRelationsPage(
                                          work: widget.work['id'] as String,
                                        ),
                                      ),
                                    );
                                  }
                                  if ([
                                    'scoped-cover',
                                    'scoped-backdrop',
                                    'restore-fields',
                                  ].contains(value)) {
                                    unawaited(_editScopedDetails(value));
                                  }
                                  if (value == 'hide') widget.onHide?.call();
                                  if (value == 'delete') widget.onDelete();
                                },
                                itemBuilder: (_) => [
                                  PopupMenuItem(
                                    value: 'metadata',
                                    child: ListTile(
                                      leading: Icon(Icons.edit_note),
                                      title: Text(context.l10n.editMetadata),
                                    ),
                                  ),
                                  PopupMenuItem(
                                    value: 'manual',
                                    child: ListTile(
                                      leading: const Icon(Icons.rule),
                                      title: Text(context.l10n.manualEdit),
                                    ),
                                  ),
                                  PopupMenuItem(
                                    value: 'cover',
                                    child: ListTile(
                                      leading: const Icon(
                                        Icons.crop_portrait_outlined,
                                      ),
                                      title: Text(context.l10n.editCover),
                                    ),
                                  ),
                                  if (backdropSpaceAvailable &&
                                      (scoped || widget.onEditBackdrop != null))
                                    PopupMenuItem(
                                      value: 'backdrop',
                                      child: ListTile(
                                        leading: const Icon(
                                          Icons.crop_landscape_outlined,
                                        ),
                                        title: Text(context.l10n.editBackdrop),
                                      ),
                                    ),
                                  if (scoped) ...[
                                    PopupMenuItem(
                                      value: 'restore-fields',
                                      child: Text(
                                        Localizations.localeOf(
                                                  context,
                                                ).languageCode ==
                                                'zh'
                                            ? '恢复自动资料'
                                            : 'Restore automatic fields',
                                      ),
                                    ),
                                  ],
                                  if (Catalog.instance.chapterRelationsEnabled)
                                    PopupMenuItem(
                                      value: 'chapter-relations',
                                      child: Text(
                                        Localizations.localeOf(
                                                  context,
                                                ).languageCode ==
                                                'zh'
                                            ? '章节与版本'
                                            : 'Chapters and editions',
                                      ),
                                    ),
                                  PopupMenuDivider(),
                                  if (widget.onHide != null)
                                    PopupMenuItem(
                                      value: 'hide',
                                      child: ListTile(
                                        leading: const Icon(
                                          Icons.visibility_off_outlined,
                                        ),
                                        title: Text(context.hideWorkAction),
                                      ),
                                    ),
                                  PopupMenuItem(
                                    value: 'delete',
                                    child: ListTile(
                                      leading: Icon(
                                        Icons.delete_outline,
                                        color: widget.onHide != null
                                            ? Theme.of(
                                                context,
                                              ).colorScheme.error
                                            : null,
                                      ),
                                      title: Text(
                                        context.l10n.removeTitleAction,
                                        style: widget.onHide != null
                                            ? TextStyle(
                                                color: Theme.of(
                                                  context,
                                                ).colorScheme.error,
                                              )
                                            : null,
                                      ),
                                    ),
                                  ),
                                ],
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
        },
      ),
    );
  }

  Widget information(
    String title,
    String overview,
    Object? score,
    List<String> tags,
    Color secondary,
    Color muted,
    bool desktop, {
    bool fullWidthPlay = false,
  }) {
    final year = widget.standalonePart == null
        ? widget.work['year']?.toString() ??
              details['year']?.toString().split('-').first
        : widget.standalonePart?['year']?.toString();
    final current = resume;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: desktop ? 30 : 25,
            fontWeight: FontWeight.w700,
            height: 1.2,
          ),
        ),
        const SizedBox(height: 12),
        if ((details['recognized_synopses'] as List?)?.length case final count?
            when count > 1)
          Wrap(
            spacing: 4,
            children: [
              for (var i = 0; i < count; i++)
                if ((details['recognized_synopses'] as List)[i]['label']
                    is String)
                  ChoiceChip(
                    label: Text(
                      (details['recognized_synopses'] as List)[i]['label']
                          as String,
                    ),
                    selected: (synopsisIndex ?? 0) == i,
                    onSelected: (selected) => setState(() {
                      synopsisIndex = selected ? i : null;
                      expandedSummary = false;
                    }),
                  ),
            ],
          ),
        Wrap(
          spacing: 18,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (score is num && score > 0)
              Text(
                '★ ${score.toStringAsFixed(1)}',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            if (year != null) Text(year, style: TextStyle(color: secondary)),
            Text(
              context.l10n.detailEpisodeCount(episodes.length),
              style: TextStyle(color: secondary),
            ),
          ],
        ),
        const SizedBox(height: 22),
        SizedBox(
          width: fullWidthPlay ? double.infinity : null,
          child: FilledButton.icon(
            onPressed: current == null ? null : () => play(current),
            icon: const Icon(Icons.play_arrow_rounded),
            label: Text(
              current == null
                  ? context.l10n.noMainFeature
                  : fraction(current) > 0
                  ? context.l10n.resumeEpisode(episodeLabel(current))
                  : context.l10n.startPlayback,
            ),
          ),
        ),
        if (tags.isNotEmpty) ...[
          const SizedBox(height: 14),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final tag in tags.take(12))
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: .055),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(
                    tag,
                    style: TextStyle(fontSize: 12, color: secondary),
                  ),
                ),
            ],
          ),
        ],
        const SizedBox(height: 16),
        _synopsis(overview, secondary),
      ],
    );
  }

  Widget _synopsis(String overview, Color color) {
    const collapsedLines = 5;
    final style = TextStyle(fontSize: 14, color: color, height: 1.8);
    if (overview.isEmpty) return Text(context.l10n.noSynopsis, style: style);

    return LayoutBuilder(
      builder: (context, bounds) {
        final defaults = DefaultTextStyle.of(context);
        final span = TextSpan(
          text: overview,
          style: defaults.style
              .merge(style)
              .copyWith(
                fontWeight: MediaQuery.boldTextOf(context)
                    ? FontWeight.bold
                    : null,
                height: MediaQuery.maybeLineHeightScaleFactorOverrideOf(
                  context,
                ),
                letterSpacing: MediaQuery.maybeLetterSpacingOverrideOf(context),
                wordSpacing: MediaQuery.maybeWordSpacingOverrideOf(context),
              ),
        );
        final direction = Directionality.of(context);
        final scaler = MediaQuery.textScalerOf(context);
        final locale = Localizations.maybeLocaleOf(context);
        final align = defaults.textAlign ?? TextAlign.start;
        final heightBehavior =
            defaults.textHeightBehavior ??
            DefaultTextHeightBehavior.maybeOf(context);
        final painter = TextPainter(
          text: span,
          textDirection: direction,
          textScaler: scaler,
          locale: locale,
          textAlign: align,
          textWidthBasis: defaults.textWidthBasis,
          textHeightBehavior: heightBehavior,
          maxLines: collapsedLines,
          ellipsis: '…',
        )..layout(maxWidth: bounds.maxWidth);
        final canExpand = painter.didExceedMaxLines;
        painter.dispose();
        final showFullText = canExpand && expandedSummary;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            RichText(
              text: span,
              textDirection: direction,
              textScaler: scaler,
              locale: locale,
              textAlign: align,
              textWidthBasis: defaults.textWidthBasis,
              textHeightBehavior: heightBehavior,
              maxLines: showFullText ? null : collapsedLines,
              overflow: showFullText
                  ? TextOverflow.visible
                  : TextOverflow.ellipsis,
            ),
            if (canExpand)
              TextButton(
                onPressed: () =>
                    setState(() => expandedSummary = !expandedSummary),
                child: Text(
                  showFullText
                      ? context.l10n.collapseSynopsis
                      : context.l10n.expandSynopsis,
                ),
              ),
          ],
        );
      },
    );
  }

  Widget sectionTab(String value, String title, int count, Color muted) {
    final chosen = section == value;
    return InkWell(
      onTap: () => setState(() {
        section = value;
        expanded = false;
        if (rail.hasClients) rail.jumpTo(0);
      }),
      child: AnimatedContainer(
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
        decoration: BoxDecoration(
          color: chosen
              ? NipaPlayStyle.accent.withValues(alpha: .1)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(22),
        ),
        child: Text(
          '$title  $count',
          softWrap: false,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: chosen ? Theme.of(context).colorScheme.primary : muted,
          ),
        ),
      ),
    );
  }

  Widget episodeTile(Map<String, Object?> asset, Color secondary) {
    // TV uses episode stills; a movie main feature uses landscape work artwork.
    final info = episodeInfo(asset);
    final still = info['still']?.toString();
    final showLabel =
        !(isMovie && asset['category'] == 'main' && episodes.length == 1);
    final ova =
        asset['category'] == 'extra' && EpisodeMetadata.isOva(extraType(asset));
    final placeholder = episodeCover(
      asset,
      blank: info['blank_still'] == true || _independentMovie(asset),
      showLabel: showLabel && !ova,
    );
    final ratio = fraction(asset);
    final status = ratio == 0
        ? context.l10n.unwatchedStatus
        : '${(ratio * 100).floor()}%';
    return InkWell(
      key: ValueKey('detail-episode:${asset['relative_path']}'),
      onTap: () => play(asset, offerVersions: true),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (still == null || still.trim().isEmpty)
                    placeholder
                  else
                    ManagedImage(
                      still,
                      owner: widget.work['id'].toString(),
                      artwork: ManagedArtwork.still,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => placeholder,
                      frameBuilder: (_, child, frame, synchronous) =>
                          frame == null && !synchronous
                          ? placeholder
                          : Stack(
                              fit: StackFit.expand,
                              children: [
                                child,
                                if (showLabel && !ova)
                                  Positioned(
                                    top: 7,
                                    left: 7,
                                    child: badge(episodeLabel(asset)),
                                  ),
                              ],
                            ),
                    ),
                  if (ova)
                    Positioned(
                      top: 7,
                      left: 7,
                      child: badge(episodeLabel(asset)),
                    ),
                  Positioned(
                    top: 7,
                    right: 7,
                    child: badge(
                      status,
                      background: ratio > 0
                          ? NipaPlayStyle.accent
                          : Colors.black54,
                    ),
                  ),
                  if (asset['category'] == 'main' &&
                      variantsFor(asset).length > 1)
                    Positioned(
                      bottom: 7,
                      left: 7,
                      child: badge(
                        context.l10n.detailVersionCount(
                          variantsFor(asset).length,
                        ),
                      ),
                    ),
                  if (ratio > 0)
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      child: LinearProgressIndicator(
                        value: ratio,
                        color: NipaPlayStyle.accent,
                        backgroundColor: Colors.black38,
                        minHeight: 3,
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Tooltip(
            message: episodeTitle(asset),
            child: Text(
              episodeTitle(asset),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, height: 1.4, color: secondary),
            ),
          ),
        ],
      ),
    );
  }

  String extraCoverLabel(Map<String, Object?> asset) {
    final type = extraType(asset);
    if (type == '其他') return context.l10n.otherExtra;
    final extracted = CloudMediaAssetPresentation.extraTitle(asset);
    final number = extracted == null
        ? null
        : RegExp(r'\d+[A-Za-z]?$').firstMatch(extracted)?.group(0);
    final peers = allExtras.where((a) => extraType(a) == type).toList();
    final index = peers.indexWhere(
      (a) =>
          a['id'] == asset['id'] &&
          a['relative_path'] == asset['relative_path'],
    );
    return '$type ${(number ?? asset['episode']?.toString() ?? '${index + 1}').padLeft(2, '0')}';
  }

  Widget episodeCover(
    Map<String, Object?> asset, {
    bool blank = false,
    required bool showLabel,
  }) {
    final art = blank
        ? null
        : [
                details['backdrop'],
                Catalog.preferredPoster(widget.work),
                widget.work['poster'],
                details['poster'],
                widget.work['poster_fallback'],
              ]
              .whereType<String>()
              .where((url) => url.trim().isNotEmpty)
              .firstOrNull;
    final surface = Theme.of(context).colorScheme.surfaceContainerLow;
    return Stack(
      key: ValueKey('detail-episode-placeholder:${asset['relative_path']}'),
      fit: StackFit.expand,
      children: [
        ColoredBox(color: surface),
        if (art != null)
          Opacity(
            opacity: .5,
            child: ImageFiltered(
              imageFilter: ui.ImageFilter.blur(sigmaX: 1.5, sigmaY: 1.5),
              child: ManagedImage(
                art,
                owner: widget.work['id'].toString(),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const SizedBox.expand(),
              ),
            ),
          ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                surface.withValues(alpha: .35),
                surface.withValues(alpha: .08),
              ],
            ),
          ),
        ),
        if (art == null)
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(right: 24),
              child: Icon(
                extraType(asset) == 'MENU'
                    ? Icons.menu_book_outlined
                    : Icons.local_movies_outlined,
                size: 54,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: .09),
              ),
            ),
          ),
        if (showLabel)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 22),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  asset['category'] == 'extra'
                      ? extraCoverLabel(asset)
                      : episodeLabel(asset),
                  style: TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.2,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget badge(String value, {Color background = Colors.black54}) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(3),
    ),
    child: Text(
      value,
      style: const TextStyle(color: Colors.white, fontSize: 10),
    ),
  );
}

class _MouseScroll extends MaterialScrollBehavior {
  const _MouseScroll();
  @override
  Set<PointerDeviceKind> get dragDevices => {
    ...super.dragDevices,
    PointerDeviceKind.mouse,
  };
}
