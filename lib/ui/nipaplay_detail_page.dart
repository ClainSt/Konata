import 'dart:async';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import '../core/catalog.dart';
import '../core/detail_metadata.dart';
import 'nipaplay_style.dart';
import 'watch_page.dart';

/// CCPlayer adaptation of the NipaPlay Personal detail screen.
class NipaPlayDetailPage extends StatefulWidget {
  const NipaPlayDetailPage({
    super.key,
    required this.work,
    required this.assets,
    required this.onManage,
    required this.onBack,
  });
  final Map<String, Object?> work;
  final List<Map<String, Object?>> assets;
  final VoidCallback onManage, onBack;
  @override
  State<NipaPlayDetailPage> createState() => _NipaPlayDetailPageState();
}

class _NipaPlayDetailPageState extends State<NipaPlayDetailPage> {
  Map<String, dynamic> details = {};
  Map<String, Map<String, Object?>> progress = {};
  bool loading = false, expanded = false, expandedSummary = false;
  String section = 'main';
  int generation = 0;
  final rail = ScrollController();

  @override
  void initState() {
    super.initState();
    refresh();
  }

  @override
  void didUpdateWidget(covariant NipaPlayDetailPage old) {
    super.didUpdateWidget(old);
    if (Catalog.detailIdentity(old.work) !=
            Catalog.detailIdentity(widget.work) ||
        old.work['id'] != widget.work['id']) {
      details = {};
      refresh();
    }
  }

  @override
  void dispose() {
    generation++;
    rail.dispose();
    super.dispose();
  }

  Future<void> refresh({bool force = false}) async {
    final seq = ++generation;
    final cat = Catalog.instance;
    final cached = await cat.readWorkDetails(widget.work);
    final records = await cat.progressForWork(widget.work['id'].toString());
    if (!mounted || seq != generation) return;
    setState(() {
      progress = records;
      if (cached != null) details = cached;
    });
    final fetched = await cat.detailFetchedAt(widget.work['id'].toString());
    if (!force &&
        cached != null &&
        fetched != null &&
        DateTime.now().difference(fetched) < const Duration(days: 3)) {
      return;
    }
    if (widget.work['tmdb_id'] == null && widget.work['bangumi_id'] == null) {
      return;
    }
    final svc = DetailMetadataService();
    setState(() => loading = true);
    try {
      final fresh = await svc.fetch(widget.work);
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
      if (mounted && seq == generation) setState(() => loading = false);
    }
  }

  List<Map<String, Object?>> get episodes => _sorted('main');
  List<Map<String, Object?>> get extras => _sorted('extra');
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

  Map<String, dynamic> episodeInfo(Map<String, Object?> asset) {
    final map = details[asset['category'] == 'extra' ? 'specials' : 'episodes'];
    final id = asset['episode']?.toString() ?? '';
    if (map is Map && map[id] is Map) {
      return Map<String, dynamic>.from(map[id] as Map);
    }
    return {};
  }

  String episodeLabel(Map<String, Object?> asset) {
    final n = asset['episode'];
    return asset['category'] == 'extra'
        ? (n == null ? '特典' : 'SP $n')
        : (n == null ? '正片' : '第 $n 集');
  }

  String episodeTitle(Map<String, Object?> asset) {
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

  Future<void> play(Map<String, Object?> asset) async {
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => WatchPage(asset: asset)),
    );
    if (mounted) await refresh();
  }

  Widget image(String? url, {Alignment alignment = Alignment.center}) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    if (url == null || url.isEmpty) {
      return ColoredBox(
        color: dark ? const Color(0xff333333) : const Color(0xffeeeeee),
        child: const Center(
          child: Icon(Icons.movie_outlined, size: 34, color: Colors.grey),
        ),
      );
    }
    return Image.network(
      url,
      fit: BoxFit.cover,
      alignment: alignment,
      errorBuilder: (_, _, _) => ColoredBox(
        color: Colors.black.withValues(alpha: .06),
        child: const Center(
          child: Icon(Icons.movie_outlined, color: Colors.grey),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context), dark = theme.brightness == Brightness.dark;
    final text = theme.colorScheme.onSurface;
    final secondary = text.withValues(alpha: .7),
        muted = text.withValues(alpha: .55);
    final surface = dark ? const Color(0xff1f1f1f) : Colors.white;
    final title = widget.work['title']?.toString() ?? '未命名作品';
    final rawPoster = widget.work['poster']?.toString();
    final poster = rawPoster?.isNotEmpty == true
        ? rawPoster
        : details['poster']?.toString();
    final backdrop = details['backdrop']?.toString().isNotEmpty == true
        ? details['backdrop']?.toString()
        : poster;
    final rawOverview = widget.work['overview']?.toString().trim();
    final overview = rawOverview?.isNotEmpty == true
        ? rawOverview!
        : details['overview']?.toString() ?? '';
    final cast = (details['characters'] as List? ?? [])
        .whereType<Map>()
        .toList();
    final tags = (details['tags'] as List? ?? [])
        .map((e) => e.toString())
        .toList();
    final selected = section == 'main' ? episodes : extras;
    return Scaffold(
      backgroundColor: surface,
      body: LayoutBuilder(
        builder: (ctx, size) {
          final wide = size.maxWidth >= 650, desktop = size.maxWidth >= 1100;
          final inset = desktop
              ? 40.0
              : wide
              ? 28.0
              : 16.0;
          final width = (size.maxWidth - inset * 2).clamp(0.0, 1560.0);
          final posterWidth = wide
              ? (desktop ? 245.0 : 170.0)
              : (width * .66).clamp(170.0, 310.0);
          return Stack(
            fit: StackFit.expand,
            children: [
              if (backdrop != null)
                Positioned.fill(
                  child: image(backdrop, alignment: Alignment.topCenter),
                ),
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: const [0, .58, 1],
                      colors: dark
                          ? const [
                              Color(0xcc1f1f1f),
                              Color(0xed1f1f1f),
                              Color(0xff1f1f1f),
                            ]
                          : [
                              Colors.white.withValues(alpha: .72),
                              Colors.white.withValues(alpha: .91),
                              Colors.white,
                            ],
                    ),
                  ),
                ),
              ),
              SafeArea(
                child: ScrollConfiguration(
                  behavior: const _MouseScroll(),
                  child: SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(inset, 80, inset, 48),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: width),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (wide)
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SizedBox(
                                    width: posterWidth,
                                    height: posterWidth * 1.5,
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: image(poster),
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
                              Center(
                                child: SizedBox(
                                  width: posterWidth,
                                  height: posterWidth * 1.5,
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: image(poster),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 20),
                              information(
                                title,
                                overview,
                                details['score'],
                                tags,
                                secondary,
                                muted,
                                false,
                              ),
                            ],
                            if (cast.isNotEmpty) ...[
                              const SizedBox(height: 28),
                              Text(
                                '角色',
                                style: TextStyle(
                                  fontSize: 15,
                                  color: secondary,
                                ),
                              ),
                              const SizedBox(height: 14),
                              SizedBox(
                                height: 146,
                                child: ListView.separated(
                                  scrollDirection: Axis.horizontal,
                                  itemCount: cast.length,
                                  separatorBuilder: (_, _) =>
                                      const SizedBox(width: 16),
                                  itemBuilder: (ctx, i) {
                                    final c = cast[i];
                                    final actors = c['actors'] is List
                                        ? (c['actors'] as List).join(' / ')
                                        : '';
                                    return SizedBox(
                                      width: 96,
                                      child: Column(
                                        children: [
                                          SizedBox(
                                            height: 80,
                                            width: 80,
                                            child: ClipOval(
                                              child: image(
                                                c['image']?.toString(),
                                              ),
                                            ),
                                          ),
                                          const SizedBox(height: 7),
                                          Text(
                                            c['name']?.toString() ?? '',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              color: text,
                                              fontSize: 12,
                                            ),
                                          ),
                                          const SizedBox(height: 3),
                                          Text(
                                            actors,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            textAlign: TextAlign.center,
                                            style: TextStyle(
                                              color: muted,
                                              fontSize: 11,
                                            ),
                                          ),
                                        ],
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ],
                            const SizedBox(height: 30),
                            Wrap(
                              alignment: WrapAlignment.spaceBetween,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              spacing: 16,
                              runSpacing: 8,
                              children: [
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    sectionTab(
                                      'main',
                                      '正片',
                                      episodes.length,
                                      muted,
                                    ),
                                    const SizedBox(width: 22),
                                    sectionTab(
                                      'extra',
                                      '特典',
                                      extras.length,
                                      muted,
                                    ),
                                  ],
                                ),
                                TextButton.icon(
                                  onPressed: () =>
                                      setState(() => expanded = !expanded),
                                  icon: Icon(
                                    expanded
                                        ? Icons.view_carousel_outlined
                                        : Icons.view_list_outlined,
                                    size: 18,
                                  ),
                                  label: Text(expanded ? '收起列表' : '完整列表'),
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            if (selected.isEmpty)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 30,
                                ),
                                child: Text(
                                  section == 'extra' ? '暂无特典文件' : '暂无已关联正片',
                                  style: TextStyle(color: muted),
                                ),
                              )
                            else if (expanded)
                              LayoutBuilder(
                                builder: (ctx, layout) {
                                  final count = (layout.maxWidth / 240)
                                      .floor()
                                      .clamp(1, 6);
                                  final tileWidth =
                                      (layout.maxWidth - 12 * (count - 1)) /
                                      count;
                                  return Wrap(
                                    spacing: 12,
                                    runSpacing: 18,
                                    children: [
                                      for (final asset in selected)
                                        SizedBox(
                                          width: tileWidth,
                                          child: episodeTile(asset, secondary),
                                        ),
                                    ],
                                  );
                                },
                              )
                            else
                              SizedBox(
                                height: 238,
                                child: Scrollbar(
                                  controller: rail,
                                  thumbVisibility: true,
                                  child: ListView.separated(
                                    controller: rail,
                                    scrollDirection: Axis.horizontal,
                                    itemCount: selected.length,
                                    separatorBuilder: (_, _) =>
                                        const SizedBox(width: 12),
                                    itemBuilder: (ctx, i) => SizedBox(
                                      width: 260,
                                      child: episodeTile(
                                        selected[i],
                                        secondary,
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
                ),
              ),
              // Keep navigation and association management accessible while
              // the poster, description and episodes scroll underneath.
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: SafeArea(
                  bottom: false,
                  child: Container(
                    key: const ValueKey('detail-fixed-toolbar'),
                    height: 64,
                    decoration: BoxDecoration(
                      color: surface.withValues(alpha: .96),
                      border: Border(
                        bottom: BorderSide(color: text.withValues(alpha: .09)),
                      ),
                    ),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: width),
                        child: Row(
                          children: [
                            IconButton(
                              key: const ValueKey('detail-back-button'),
                              tooltip: '返回媒体库',
                              onPressed: widget.onBack,
                              icon: Icon(Icons.arrow_back, color: text),
                            ),
                            const Spacer(),
                            TextButton.icon(
                              key: const ValueKey('detail-manage-button'),
                              onPressed: widget.onManage,
                              icon: const Icon(Icons.edit_outlined, size: 18),
                              label: const Text('关联管理'),
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
    bool desktop,
  ) {
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
                style: const TextStyle(
                  color: NipaPlayStyle.accent,
                  fontWeight: FontWeight.w600,
                ),
              ),
            if (year != null) Text(year, style: TextStyle(color: secondary)),
            Text('${episodes.length} 集', style: TextStyle(color: secondary)),
          ],
        ),
        const SizedBox(height: 22),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            FilledButton.icon(
              onPressed: current == null ? null : () => play(current),
              icon: const Icon(Icons.play_arrow_rounded),
              label: Text(
                current == null
                    ? '暂无正片'
                    : fraction(current) > 0
                    ? '继续 ${episodeLabel(current)}'
                    : '开始播放',
              ),
            ),
          ],
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
          overview.isNotEmpty ? overview : '暂无作品简介',
          maxLines: expandedSummary ? null : 5,
          overflow: expandedSummary
              ? TextOverflow.visible
              : TextOverflow.ellipsis,
          style: TextStyle(fontSize: 14, color: secondary, height: 1.8),
        ),
        if (overview.length > 180)
          TextButton(
            onPressed: () => setState(() => expandedSummary = !expandedSummary),
            child: Text(expandedSummary ? '收起简介' : '展开简介'),
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
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: chosen ? NipaPlayStyle.accent : Colors.transparent,
              width: 3,
            ),
          ),
        ),
        child: Text(
          '$title  $count',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: chosen ? NipaPlayStyle.accent : muted,
          ),
        ),
      ),
    );
  }

  Widget episodeTile(Map<String, Object?> asset, Color secondary) {
    final still = episodeInfo(asset)['still']?.toString().isNotEmpty == true
        ? episodeInfo(asset)['still']?.toString()
        : details['backdrop']?.toString() ?? widget.work['poster']?.toString();
    final ratio = fraction(asset);
    final status = ratio >= .95
        ? '已看'
        : ratio > 0
        ? '继续播放'
        : '未看';
    return InkWell(
      key: ValueKey('detail-episode:${asset['relative_path']}'),
      onTap: () => play(asset),
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
                  image(still),
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
          Text(
            episodeTitle(asset),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13, height: 1.4, color: secondary),
          ),
        ],
      ),
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
