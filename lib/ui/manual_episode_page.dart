import 'package:flutter/material.dart';
import '../core/catalog.dart';
import '../core/metadata.dart';
import '../l10n/strings.dart';

class ManualEpisodePage extends StatefulWidget {
  const ManualEpisodePage({
    super.key,
    required this.work,
    required this.assets,
    this.searchTitles,
    this.loadTitle,
  });
  final Map<String, Object?> work;
  final List<Map<String, Object?>> assets;
  final Future<List<Candidate>> Function(String)? searchTitles;
  final Future<Map<String, dynamic>> Function(int, int?)? loadTitle;
  @override
  State<ManualEpisodePage> createState() => _ManualEpisodePageState();
}

class _ManualEpisodePageState extends State<ManualEpisodePage> {
  final query = TextEditingController();
  List<Candidate> results = [];
  List<Map> seasons = [], episodes = [];
  Candidate? selected;
  int? season;
  bool busy = false;
  String? error;
  final mappings = <String, ({int season, int? episode})>{};

  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }

  Future<void> run(Future<void> Function() action) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) setState(() => error = 'failed');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> choose(Candidate candidate) => run(() async {
    final data =
        await (widget.loadTitle?.call(candidate.id, null) ??
            Metadata.tvDetails(candidate.id));
    if (!mounted) return;
    setState(() {
      if (selected?.id != candidate.id) mappings.clear();
      selected = candidate;
      seasons = (data['seasons'] as List? ?? [])
          .whereType<Map>()
          .where((s) => s['season_number'] is int)
          .toList();
      season = null;
      episodes = [];
    });
  });

  Future<void> chooseSeason(int number) => run(() async {
    final data =
        await (widget.loadTitle?.call(selected!.id, number) ??
            Metadata.tvDetails(selected!.id, season: number));
    if (!mounted) return;
    setState(() {
      season = number;
      episodes = (data['episodes'] as List? ?? [])
          .whereType<Map>()
          .where((e) => e['episode_number'] is int)
          .toList();
    });
  });

  Future<void> match(Map<String, Object?> asset) async {
    final id = asset['id'].toString();
    final result = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(ctx.l10n.chooseEpisode),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, -1),
            child: Text(ctx.l10n.keepMatch),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 0),
            child: Text(ctx.l10n.otherExtra),
          ),
          for (final episode in episodes)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, episode['episode_number']),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Text(
                  '${ctx.l10n.episodeLabel(episode['episode_number'] as int)} · ${episode['name'] ?? ''}',
                  softWrap: false,
                ),
              ),
            ),
        ],
      ),
    );
    if (!mounted || result == null) return;
    setState(() {
      if (result == -1) {
        mappings.remove(id);
      } else {
        mappings[id] = (season: season!, episode: result == 0 ? null : result);
      }
    });
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: Scaffold(
      appBar: AppBar(title: Text(context.l10n.manualEdit)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(context.l10n.mappingHint),
          const SizedBox(height: 12),
          TextField(
            controller: query,
            enabled: !busy,
            decoration: InputDecoration(labelText: context.l10n.nameOrId),
            onSubmitted: (_) => search(),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: busy ? null : search,
              child: Text(context.l10n.search),
            ),
          ),
          if (busy) const LinearProgressIndicator(),
          if (error != null) Text(context.l10n.mappingFailed),
          for (final item in selected == null ? results : <Candidate>[])
            ListTile(
              selected: selected?.id == item.id,
              title: Text(item.title),
              subtitle: Text('TMDB ${item.id} · ${item.year ?? ''}'),
              trailing: const Icon(Icons.chevron_right),
              onTap: busy ? null : () => choose(item),
            ),
          if (selected != null) ...[
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(selected!.title),
              subtitle: Text('TMDB ${selected!.id}'),
            ),
            Text(
              context.l10n.chooseSeason,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final item in seasons)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(
                          '${item['season_number']} · ${item['name'] ?? ''}',
                          softWrap: false,
                        ),
                        selected: season == item['season_number'],
                        onSelected: busy
                            ? null
                            : (_) => chooseSeason(item['season_number'] as int),
                      ),
                    ),
                ],
              ),
            ),
          ],
          if (season != null) ...[
            const Divider(height: 32),
            Text(
              context.l10n.chooseEpisode,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            for (final asset in widget.assets)
              ListTile(
                title: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Text(asset['name'].toString(), softWrap: false),
                ),
                subtitle: Text(
                  mappings.containsKey(asset['id'].toString())
                      ? '${mappings[asset['id'].toString()]!.season} · ${mappings[asset['id'].toString()]!.episode ?? context.l10n.otherExtra}'
                      : context.l10n.keepMatch,
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: busy || season == null ? null : () => match(asset),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton(
                onPressed: busy || mappings.isEmpty || selected == null
                    ? null
                    : () => run(() async {
                        await Catalog.instance.saveEpisodeMappings(
                          widget.work['id'].toString(),
                          selected!,
                          mappings,
                        );
                        if (context.mounted) Navigator.pop(context);
                      }),
                child: Text(context.l10n.save),
              ),
            ),
          ],
        ],
      ),
    ),
  );

  Future<void> search() => run(() async {
    final found =
        await (widget.searchTitles?.call(query.text) ??
            Metadata.search(query.text, 'tmdb'));
    if (mounted) {
      setState(() {
        results = found.where((c) => c.mediaType == 'tv').toList();
        selected = null;
        seasons = [];
        season = null;
        episodes = [];
        mappings.clear();
      });
    }
  });
}
