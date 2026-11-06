import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../core/bangumi_episode_mapping.dart';
import '../core/watch_event_origin.dart';
import '../l10n/strings.dart';

class BangumiEpisodeMappingDialog extends StatefulWidget {
  const BangumiEpisodeMappingDialog({
    super.key,
    required this.store,
    required this.assetId,
    required this.episodeKey,
    required this.title,
    this.verifier,
  });
  final BangumiEpisodeMapping store;
  final String assetId, episodeKey, title;
  final BangumiEpisodeVerifier? verifier;
  @override
  State<BangumiEpisodeMappingDialog> createState() => _MappingState();
}

class _MappingState extends State<BangumiEpisodeMappingDialog> {
  final subject = TextEditingController(), episode = TextEditingController();
  late final client = http.Client();
  late final verifier = widget.verifier ?? BangumiEpisodeVerifier(client);
  bool busy = true, failed = false;
  int type = 0, revision = 0;
  int? head;
  Map<String, Object?>? preview, current;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final value = await widget.store.current(widget.episodeKey);
      final id = await widget.store.headId(widget.episodeKey);
      final rev = await WatchEventOrigin.revision(
        widget.store.db,
        widget.assetId,
      );
      if (!mounted) return;
      setState(() {
        current = value;
        head = id;
        revision = rev;
        busy = false;
        if (value != null) {
          subject.text = '${value['subject_id']}';
          episode.text = '${value['episode_id']}';
          type = value['episode_type'] as int;
        }
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          failed = true;
          busy = false;
        });
      }
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      busy = true;
      failed = false;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) setState(() => failed = true);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    subject.dispose();
    episode.dispose();
    client.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: Text(context.l10n.bangumiEpisodeMapping),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.title),
              const SizedBox(height: 12),
              Text(context.l10n.bangumiMappingDescription),
              TextField(
                key: const ValueKey('bgm-subject'),
                controller: subject,
                enabled: !busy,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: context.l10n.bangumiSubjectId,
                ),
                onChanged: (_) => setState(() => preview = null),
              ),
              TextField(
                key: const ValueKey('bgm-episode'),
                controller: episode,
                enabled: !busy,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: context.l10n.bangumiEpisodeId,
                ),
                onChanged: (_) => setState(() => preview = null),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                initialValue: type,
                isExpanded: true,
                key: ValueKey('bgm-type-$type'),
                decoration: InputDecoration(
                  labelText: context.l10n.bangumiEpisodeType,
                ),
                items: [
                  DropdownMenuItem(
                    value: 0,
                    child: Text(context.l10n.bangumiMainStory),
                  ),
                  DropdownMenuItem(
                    value: 1,
                    child: Text(context.l10n.specialEpisode),
                  ),
                ],
                onChanged: busy
                    ? null
                    : (v) => setState(() {
                        type = v!;
                        preview = null;
                      }),
              ),
              if (preview != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    'Bangumi ${preview!['subject_id']} · #${preview!['episode_id']}\n${preview!['episode_sort']} · ${preview!['episode_name']}',
                  ),
                ),
              if (failed)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(context.l10n.bangumiMappingFailed),
                ),
              if (busy)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: LinearProgressIndicator(),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: Text(context.l10n.cancel),
        ),
        if (current != null)
          TextButton(
            onPressed: busy
                ? null
                : () => _run(() async {
                    await widget.store.revoke(
                      widget.episodeKey,
                      current!['id'] as int,
                    );
                    if (context.mounted) Navigator.pop(context);
                  }),
            child: Text(context.l10n.revokeBangumiMapping),
          ),
        TextButton(
          onPressed: busy
              ? null
              : () => _run(() async {
                  final s = int.tryParse(subject.text.trim()),
                      e = int.tryParse(episode.text.trim());
                  if (s == null || e == null) {
                    throw const FormatException('IDs required');
                  }
                  final data = await verifier.verify(s, e, type);
                  if (mounted) setState(() => preview = data);
                }),
          child: Text(context.l10n.verifyBangumiEpisode),
        ),
        FilledButton(
          onPressed: busy || preview == null
              ? null
              : () => _run(() async {
                  final p = preview!;
                  await widget.store.confirm(
                    verifier: verifier,
                    assetId: widget.assetId,
                    expectedKey: widget.episodeKey,
                    expectedRevision: revision,
                    expectedPreviousId: head,
                    subjectId: p['subject_id'] as int,
                    episodeId: p['episode_id'] as int,
                    expectedType: p['episode_type'] as int,
                  );
                  if (context.mounted) Navigator.pop(context);
                }),
          child: Text(context.l10n.save),
        ),
      ],
    ),
  );
}
