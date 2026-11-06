import '../l10n/strings.dart';
import 'package:flutter/material.dart';
import '../core/catalog.dart';
import '../core/playback_history.dart';
import '../core/logical_episode_store.dart';
import '../core/episode_metadata.dart';
import 'managed_image.dart';
import 'watch_page.dart';
import 'bangumi_episode_mapping_dialog.dart';
import '../core/bangumi_episode_mapping.dart';

class PlaybackHistoryPage extends StatefulWidget {
  const PlaybackHistoryPage({
    super.key,
    this.history,
    this.onPlay,
    this.embedded = false,
    this.onBack,
  });
  final PlaybackHistory? history;
  final Future<void> Function(Map<String, Object?> asset)? onPlay;
  final bool embedded;
  final VoidCallback? onBack;

  @override
  State<PlaybackHistoryPage> createState() => _PlaybackHistoryPageState();
}

class _PlaybackHistoryPageState extends State<PlaybackHistoryPage> {
  late final history = widget.history ?? PlaybackHistory(Catalog.instance.db);
  late Future<List<Map<String, Object?>>> rows = history.entries();
  bool busy = false;

  Future<void> _refresh() async {
    if (mounted) {
      setState(() {
        rows = history.entries();
      });
    }
  }

  Future<void> _change(Future<void> Function() action) async {
    setState(() => busy = true);
    try {
      await action();
      await _refresh();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.l10n.historyFailed)));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<bool> _confirm(bool all) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            all
                ? context.l10n.clearHistoryQuestion
                : context.l10n.removeHistoryQuestion,
          ),
          content: Text(
            '${context.l10n.removeHistoryDescription}\n\n${context.l10n.historyEventsRetained}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(context.l10n.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(context.l10n.confirmDelete),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _confirmIdentity(Map<String, Object?> row) async {
    final key = row['_candidate_key'] as String;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.confirmEpisodeIdentity),
        content: SingleChildScrollView(
          child: Text(
            '${row['work_title']}\n${row['name']}\nTMDB ${(row['_work'] as Map)['tmdb_id']} · S${row['season']} · E${row['episode']}\n\n${context.l10n.confirmEpisodeDescription}',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.confirmEpisodeIdentity),
          ),
        ],
      ),
    );
    if (accepted == true && mounted) {
      await _change(
        () => LogicalEpisodeStore(history.db).confirm(row['id'] as String, key),
      );
    }
  }

  Future<void> _play(Map<String, Object?> row) async {
    try {
      if (widget.onPlay != null) {
        await widget.onPlay!(row);
      } else {
        await Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => WatchPage(asset: row)));
      }
      await _refresh();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.l10n.playFailed)));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      automaticallyImplyLeading: !widget.embedded,
      leading: widget.onBack == null
          ? null
          : IconButton(
              key: const ValueKey('history-back'),
              tooltip: context.l10n.backSettings,
              onPressed: widget.onBack,
              icon: const Icon(Icons.arrow_back),
            ),
      title: Text(context.l10n.history),
      actions: [
        IconButton(
          tooltip: context.l10n.refreshHistory,
          onPressed: busy ? null : _refresh,
          icon: const Icon(Icons.refresh),
        ),
        IconButton(
          tooltip: context.l10n.clearHistory,
          onPressed: busy
              ? null
              : () async {
                  if (await _confirm(true) && mounted) {
                    await _change(history.clear);
                  }
                },
          icon: const Icon(Icons.delete_sweep_outlined),
        ),
      ],
    ),
    body: FutureBuilder<List<Map<String, Object?>>>(
      future: rows,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(context.l10n.readHistoryFailed),
                TextButton(
                  onPressed: _refresh,
                  child: Text(context.l10n.retry),
                ),
              ],
            ),
          );
        }
        final entries = snapshot.data ?? [];
        if (entries.isEmpty) return Center(child: Text(context.l10n.noHistory));
        return ListView.separated(
          itemCount: entries.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final row = entries[index];
            final id = row['id'].toString();
            final completed =
                row['_logical_completed'] as bool? ?? row['completed'] == 1;
            final conflict = row['_logical_conflict'] == true;
            final work = row['_work'] as Map<String, Object?>;
            final info = EpisodeMetadata.lookup(
              work,
              row['_details'] as Map<String, dynamic>,
              row,
            );
            final number = row['episode'] as int?;
            final episodeName = info['name']?.toString().trim() ?? '';
            final episodeLabel = number == null
                ? ''
                : row['category'] == 'extra'
                ? '${row['extra_type'] ?? context.l10n.specialEpisode} $number'
                : context.l10n.episodeLabel(number);
            final episodeTitle = [
              if (episodeLabel.isNotEmpty) episodeLabel,
              if (episodeName.isNotEmpty && episodeName != row['work_title'])
                episodeName,
            ].join(' · ');
            final still = info['still']?.toString();
            final date = DateTime.tryParse(
              row['updated_at']?.toString() ?? '',
            )?.toLocal();
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: MediaQuery.sizeOf(context).width < 450 ? 80 : 128,
                      child: InkWell(
                        onTap: busy ? null : () => _play(row),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: still?.isNotEmpty == true
                              ? ManagedImage(still!, fit: BoxFit.cover)
                              : const ColoredBox(
                                  color: Color(0x11808080),
                                  child: Icon(Icons.movie_outlined),
                                ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Text(
                            row['work_title']?.toString() ??
                                row['name']?.toString() ??
                                context.l10n.unknownWork,
                            softWrap: false,
                          ),
                        ),
                        subtitle: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Text(
                                episodeTitle.isNotEmpty
                                    ? episodeTitle
                                    : row['name']?.toString() ?? '',
                                softWrap: false,
                              ),
                            ),
                            SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Text(
                                [
                                  if (conflict) context.l10n.watchStateConflict,
                                  '${completed ? context.l10n.watched : context.l10n.watching} · ${PlaybackHistory.time(row['position_ms'])} / ${PlaybackHistory.time(row['duration_ms'])}',
                                  if (date != null)
                                    date.toString().split('.').first,
                                ].join('\n'),
                                softWrap: false,
                              ),
                            ),
                          ],
                        ),
                        isThreeLine: true,
                        onTap: busy ? null : () => _play(row),
                        trailing: PopupMenuButton<String>(
                          enabled: !busy,
                          tooltip: context.l10n.manageHistory,
                          onSelected: (action) async {
                            if (action == 'bangumi') {
                              await showDialog<void>(
                                context: context,
                                barrierDismissible: false,
                                builder: (_) => BangumiEpisodeMappingDialog(
                                  store: BangumiEpisodeMapping(history.db),
                                  assetId: id,
                                  episodeKey: row['_logical_key'] as String,
                                  title: row['work_title']?.toString() ?? '',
                                ),
                              );
                              await _refresh();
                            } else if (action == 'identity') {
                              await _confirmIdentity(row);
                            } else if (action == 'revoke') {
                              await _change(
                                () =>
                                    LogicalEpisodeStore(history.db).revoke(id),
                              );
                            } else if (action == 'watched' ||
                                action == 'unwatched') {
                              await _change(
                                () => history.setCompleted(
                                  id,
                                  conflict ? action == 'watched' : !completed,
                                ),
                              );
                            } else if (await _confirm(false) && mounted) {
                              await _change(() => history.remove(id));
                            }
                          },
                          itemBuilder: (_) => [
                            if (row['_logical_key'] != null)
                              PopupMenuItem(
                                value: 'bangumi',
                                child: Text(context.l10n.bangumiEpisodeMapping),
                              ),
                            PopupMenuItem(
                              value: 'watched',
                              child: Text(
                                completed && !conflict
                                    ? context.l10n.markUnwatched
                                    : context.l10n.markWatched,
                              ),
                            ),
                            if (conflict)
                              PopupMenuItem(
                                value: 'unwatched',
                                child: Text(context.l10n.markUnwatched),
                              ),
                            if (row['_logical_key'] == null &&
                                row['_candidate_key'] != null &&
                                row['manual_mapping'] != true)
                              PopupMenuItem(
                                value: 'identity',
                                child: Text(
                                  context.l10n.confirmEpisodeIdentity,
                                ),
                              ),
                            if (row['_logical_key'] != null &&
                                row['manual_mapping'] != true)
                              PopupMenuItem(
                                value: 'revoke',
                                child: Text(context.l10n.revokeEpisodeIdentity),
                              ),
                            PopupMenuItem(
                              value: 'remove',
                              child: Text(context.l10n.deleteRecord),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    ),
  );
}
