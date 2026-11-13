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
  bool managing = false;
  final selected = <String>{};

  void _toggle(Map<String, Object?> row) => setState(() {
    final id = row['id'].toString();
    if (!selected.add(id)) selected.remove(id);
  });

  Future<void> _deleteSelected() async {
    final ids = selected.toSet();
    if (ids.isEmpty || !await _confirm(false, count: ids.length) || !mounted) {
      return;
    }
    await _change(() async {
      await history.removeMany(ids);
      if (mounted) setState(() => selected.removeAll(ids));
    });
  }

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

  Future<bool> _confirm(bool all, {int? count}) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            count != null
                ? context.l10n.deleteHistorySelectionQuestion(count)
                : all
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
          key: const ValueKey('history-manage'),
          tooltip: managing ? context.l10n.cancel : context.l10n.manageHistory,
          onPressed: busy
              ? null
              : () => setState(() {
                  managing = !managing;
                  selected.clear();
                }),
          icon: Icon(managing ? Icons.close : Icons.checklist_outlined),
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
        final visibleSelected = entries
            .where((row) => selected.contains(row['id']))
            .toList();
        return Column(
          children: [
            if (managing)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                child: LayoutBuilder(
                  builder: (context, bounds) {
                    final compact =
                        bounds.maxWidth <
                        520 * MediaQuery.textScalerOf(context).scale(1);
                    final allSelected =
                        visibleSelected.length == entries.length;
                    final selectLabel = allSelected
                        ? context.l10n.historyDeselectAll
                        : context.l10n.historySelectAll;
                    void selectAll() => setState(() {
                      if (allSelected) {
                        selected.clear();
                      } else {
                        selected.addAll(
                          entries.map((row) => row['id'].toString()),
                        );
                      }
                    });
                    return Row(
                      children: [
                        Expanded(
                          child: Text(
                            context.l10n.historySelectionCount(
                              visibleSelected.length,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 4),
                        if (compact)
                          IconButton(
                            key: const ValueKey('history-select-all'),
                            tooltip: selectLabel,
                            onPressed: busy ? null : selectAll,
                            icon: Icon(
                              allSelected ? Icons.deselect : Icons.select_all,
                            ),
                          )
                        else
                          TextButton(
                            key: const ValueKey('history-select-all'),
                            onPressed: busy ? null : selectAll,
                            child: Text(selectLabel),
                          ),
                        if (compact)
                          IconButton(
                            key: const ValueKey('history-delete-selected'),
                            tooltip: context.l10n.deleteRecord,
                            onPressed: busy || visibleSelected.isEmpty
                                ? null
                                : _deleteSelected,
                            icon: const Icon(Icons.delete_outline),
                          )
                        else
                          TextButton.icon(
                            key: const ValueKey('history-delete-selected'),
                            onPressed: busy || visibleSelected.isEmpty
                                ? null
                                : _deleteSelected,
                            icon: const Icon(Icons.delete_outline),
                            label: Text(context.l10n.deleteRecord),
                          ),
                        if (visibleSelected.length == 1)
                          _menu(visibleSelected.single),
                      ],
                    );
                  },
                ),
              ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, bounds) {
                  // Use this pane's live constraints, including split windows.
                  // Keep the smaller cards without scaling text or hit targets.
                  const targetWidth = 450 * .8;
                  final available = (bounds.maxWidth - 48).clamp(
                    0.0,
                    double.infinity,
                  );
                  final columns = ((available + 24) / (targetWidth + 24))
                      .ceil()
                      .clamp(1, 100);
                  final width = (available - (columns - 1) * 24) / columns;
                  return GridView.builder(
                    padding: const EdgeInsets.all(24),
                    itemCount: entries.length,
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      crossAxisSpacing: 24,
                      mainAxisSpacing: 24,
                      mainAxisExtent:
                          width * 9 / 16 +
                          28 +
                          54 * MediaQuery.textScalerOf(context).scale(1),
                    ),
                    itemBuilder: (context, index) => _card(entries[index]),
                  );
                },
              ),
            ),
          ],
        );
      },
    ),
  );
  Widget _card(Map<String, Object?> row) {
    final work = row['_work'] as Map<String, Object?>;
    final info = EpisodeMetadata.lookup(
      work,
      row['_details'] as Map<String, dynamic>,
      row,
    );
    final number = row['episode'] as int?;
    final label = number == null
        ? context.l10n.mainFeature
        : row['category'] == 'extra'
        ? '${row['extra_type'] ?? context.l10n.specialEpisode} $number'
        : context.l10n.episodeLabel(number);
    final episodeName = info['name']?.toString().trim() ?? '';
    final episodeDescription = [
      label,
      if (episodeName.isNotEmpty) episodeName,
    ].join(' · ');
    final date = DateTime.tryParse(
      row['updated_at']?.toString() ?? '',
    )?.toLocal();
    final completed =
        row['_logical_completed'] as bool? ?? row['completed'] == 1;
    // The library view already resolves artwork for the active provider scope.
    // The raw history work row cannot represent that scoped poster.
    final artworkWork = widget.history == null
        ? Catalog.instance.works.where((entry) => entry['id'] == work['id']).firstOrNull ?? work
        : work;
    final still = row['_blank_still'] == true
        ? null
        : (row['_recognized_still'] ?? info['still'])?.toString() ??
              Catalog.preferredPoster(artworkWork);
    final title =
        row['work_title']?.toString() ??
        row['name']?.toString() ??
        context.l10n.unknownWork;
    final duration = (row['duration_ms'] as num?)?.toDouble() ?? 0;
    final position = (row['position_ms'] as num?)?.toDouble() ?? 0;
    final progress = duration > 0 ? (position / duration).clamp(0.0, 1.0) : 0.0;
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AspectRatio(
          aspectRatio: 16 / 9,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(5),
            child: Stack(
              fit: StackFit.expand,
              children: [
                InkWell(
                  key: ValueKey('history-card-${row['id']}'),
                  onTap: busy
                      ? null
                      : () => managing ? _toggle(row) : _play(row),
                  child: Tooltip(
                    message: episodeDescription,
                    child: still?.isNotEmpty == true
                        ? ManagedImage(still!, fit: BoxFit.cover)
                        : ColoredBox(
                            color: colors.surfaceContainerHighest,
                            child: const Icon(Icons.videocam_outlined),
                          ),
                  ),
                ),
                Positioned(
                  top: 9,
                  left: 9,
                  child: IgnorePointer(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: .7),
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: Text(
                        label,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                ),
                if (progress > 0)
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: LinearProgressIndicator(
                      key: ValueKey('history-progress-${row['id']}'),
                      value: progress,
                      color: colors.primary,
                      backgroundColor: colors.onSurface.withValues(alpha: .15),
                      trackGap: 0,
                      stopIndicatorRadius: 0,
                      minHeight: 3,
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        InkWell(
          onTap: busy ? null : () => managing ? _toggle(row) : _play(row),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Tooltip(
                      message: title,
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(height: 5),
                    Tooltip(
                      message:
                          '${completed ? context.l10n.watched : context.l10n.watching}${date == null ? '' : ' · $date'}',
                      child: Text(
                        '${PlaybackHistory.time(row['position_ms'])} / ${PlaybackHistory.time(row['duration_ms'])}',
                        style: TextStyle(
                          color: colors.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    if (row['_logical_conflict'] == true)
                      Text(
                        context.l10n.watchStateConflict,
                        style: TextStyle(color: colors.error, fontSize: 12),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (managing)
                Checkbox(
                  key: ValueKey('history-select-${row['id']}'),
                  value: selected.contains(row['id']),
                  onChanged: busy ? null : (_) => _toggle(row),
                )
              else
                IconButton.filledTonal(
                  key: ValueKey('history-play-${row['id']}'),
                  tooltip: context.l10n.resumePlayback,
                  onPressed: busy ? null : () => _play(row),
                  icon: const Icon(Icons.play_arrow_outlined),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _menu(Map<String, Object?> row) {
    final id = row['id'].toString();
    final completed =
        row['_logical_completed'] as bool? ?? row['completed'] == 1;
    final conflict = row['_logical_conflict'] == true;
    return PopupMenuButton<String>(
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
          await _change(() => LogicalEpisodeStore(history.db).revoke(id));
        } else if (action == 'watched' || action == 'unwatched') {
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
            child: Text(context.l10n.confirmEpisodeIdentity),
          ),
        if (row['_logical_key'] != null && row['manual_mapping'] != true)
          PopupMenuItem(
            value: 'revoke',
            child: Text(context.l10n.revokeEpisodeIdentity),
          ),
        PopupMenuItem(value: 'remove', child: Text(context.l10n.deleteRecord)),
      ],
    );
  }
}
