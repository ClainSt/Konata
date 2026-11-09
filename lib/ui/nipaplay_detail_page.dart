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
import '../core/episode_grouping.dart';
import '../core/cloud_media_asset_presentation.dart';
import 'nipaplay_style.dart';
import 'horizontal_rail.dart';
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
  });
  final Map<String, Object?> work;
  final List<Map<String, Object?>> assets;
  final VoidCallback onEditMetadata, onEditCover, onDelete, onBack;
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
  final rail = ScrollController();

  @override
  void initState() {
    super.initState();
    ArtworkSettings.instance.addListener(_artworkChanged);
    refresh();
  }

  @override
  void didUpdateWidget(covariant NipaPlayDetailPage old) {
    super.didUpdateWidget(old);
    if (Catalog.detailIdentity(old.work) !=
            Catalog.detailIdentity(widget.work) ||
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
    final cached = await cat.readWorkDetails(widget.work);
    final records = await cat.progressForWork(widget.work['id'].toString());
    if (!mounted || seq != generation) return;
    setState(() {
      progress = records;
      if (cached != null) {
        details = Map<String, dynamic>.from(cached);
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
            DetailMetadataService.schemaVersion) {
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

  List<EpisodeGroup> get episodeGroups => EpisodeGrouping.main(widget.assets);
  List<Map<String, Object?>> get episodes =>
      episodeGroups.map((g) => g.preferred(progress)).toList();
  List<Map<String, Object?>> get extras => _sorted(
    'extra',
  ).where((a) => extraFilter == '全部' || extraType(a) == extraFilter).toList();
  List<Map<String, Object?>> get allExtras => _sorted('extra');
  String extraType(Map<String, Object?> asset) =>
      asset['extra_type']?.toString().isNotEmpty == true
      ? asset['extra_type'].toString()
      : CloudMediaAssetPresentation.extraType(asset);
  List<Map<String, Object?>> variantsFor(Map<String, Object?> asset) {
    final id = asset['id']?.toString();
    for (final group in episodeGroups) {
      if (group.versions.any((e) => e['id']?.toString() == id)) {
        return group.versions;
      }
    }
    return [asset];
  }

  List<Map<String, Object?>> _sorted(String category) {
    final all = widget.assets.where((a) => a['category'] == category).toList();
    all.sort((a, b) {
      final an = a['episode'] as int?, bn = b['episode'] as int?;
      if (an != null && bn != null) return an.compareTo(bn);
      if (an != null) return -1;
      if (bn != null) return 1;
      return a['name'].toString().compareTo(b['name'].toString());
    });
    return all;
  }

  Map<String, dynamic> episodeInfo(Map<String, Object?> asset) =>
      EpisodeMetadata.lookup(widget.work, details, asset);

  String episodeLabel(Map<String, Object?> asset) {
    final n = asset['episode'];
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
    if (metadataTitle?.isNotEmpty == true) return metadataTitle!;
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
    final title = episodeInfo(asset)['name']?.toString().trim();
    return title?.isNotEmpty == true
        ? title!
        : asset['episode'] == null
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
    tag: 'work-poster-${widget.work['id']}',
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
    final title = widget.work['title']?.toString() ?? context.l10n.unnamedWork;
    final posterFallback = widget.work['poster_fallback']?.toString();
    final poster =
        Catalog.preferredPoster(widget.work) ?? details['poster']?.toString();
    final backdrop = details['backdrop']?.toString().isNotEmpty == true
        ? details['backdrop']?.toString()
        : poster;
    final rawOverview = widget.work['overview']?.toString().trim();
    final overview = rawOverview?.isNotEmpty == true
        ? rawOverview!
        : details['overview']?.toString() ?? '';
    final tags = (details['tags'] as List? ?? [])
        .map((e) => e.toString())
        .toList();
    final selected = section == 'main' ? episodes : extras;
    final typeNames = allExtras.map(extraType).toSet().toList()..sort();
    return Scaffold(
      backgroundColor: surface,
      body: LayoutBuilder(
        builder: (ctx, size) {
          final wide = size.maxWidth >= 650, desktop = size.maxWidth >= 1100;
          final showBackdrop =
              ArtworkSettings.instance.backdrop &&
              wide &&
              size.maxHeight >= 500 &&
              backdrop != null;
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
                    fallbackUrl: posterFallback,
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
                                            const SizedBox(width: 22),
                                            sectionTab(
                                              'extra',
                                              context.l10n.extraFiles,
                                              allExtras.length,
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
                                  widget.onEditMetadata();
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
                                if (value == 'cover') widget.onEditCover();
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
                                    leading: Icon(Icons.image_outlined),
                                    title: Text(context.l10n.editCover),
                                  ),
                                ),
                                PopupMenuDivider(),
                                PopupMenuItem(
                                  value: 'delete',
                                  child: ListTile(
                                    leading: Icon(Icons.delete_outline),
                                    title: Text(context.l10n.removeTitleAction),
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
    final year =
        widget.work['year']?.toString() ??
        details['year']?.toString().split('-').first;
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
        Text(
          overview.isNotEmpty ? overview : context.l10n.noSynopsis,
          maxLines: expandedSummary ? null : 5,
          overflow: expandedSummary
              ? TextOverflow.visible
              : TextOverflow.ellipsis,
          style: TextStyle(fontSize: 14, color: secondary, height: 1.8),
        ),
        if (overview.length > 180)
          TextButton(
            onPressed: () => setState(() => expandedSummary = !expandedSummary),
            child: Text(
              expandedSummary
                  ? context.l10n.collapseSynopsis
                  : context.l10n.expandSynopsis,
            ),
          ),
      ],
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
    final still = episodeInfo(asset)['still']?.toString();
    final placeholder = episodeCover(asset);
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
                                Positioned(
                                  top: 7,
                                  left: 7,
                                  child: badge(episodeLabel(asset)),
                                ),
                              ],
                            ),
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

  Widget episodeCover(Map<String, Object?> asset) {
    final art = [
      details['backdrop'],
      Catalog.preferredPoster(widget.work),
      widget.work['poster'],
      details['poster'],
      widget.work['poster_fallback'],
    ].whereType<String>().where((url) => url.trim().isNotEmpty).firstOrNull;
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
