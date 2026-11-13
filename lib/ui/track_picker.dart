import '../core/subtitle_choices.dart';
import '../core/track_preferences.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import '../l10n/strings.dart';

class TrackPicker extends StatefulWidget {
  const TrackPicker({
    super.key,
    required this.subtitles,
    required this.selectedId,
    this.audioTracks = const [],
    this.subtitleTracks = const [],
    this.onAudio,
    this.onSubtitle,
    this.choices,
    this.onImport,
  });
  final List<SubtitleChoice>? choices;
  final Future<bool> Function()? onImport;
  final bool subtitles;
  final String selectedId;
  final List<AudioTrack> audioTracks;
  final List<SubtitleTrack> subtitleTracks;
  final Future<void> Function(AudioTrack)? onAudio;
  final Future<void> Function(SubtitleTrack)? onSubtitle;
  @override
  State<TrackPicker> createState() => _TrackPickerState();
}

class _TrackPickerState extends State<TrackPicker> {
  bool busy = false;
  Future<void> _select(Future<void> Function() action) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await action();
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.l10n.trackSwitchFailed)));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  String _label(String id, String? title, String? language) => switch (id) {
    'auto' => context.l10n.trackAuto,
    'no' =>
      widget.subtitles ? context.l10n.subtitlesOff : context.l10n.audioOff,
    _ => title?.trim().isNotEmpty == true ? title! : language ?? id,
  };

  String languageLabel(SubtitleTrack track) =>
      switch (TrackPreferences.subtitleLanguage(track.language, track.title)) {
        SubtitleLanguage.simplified =>
          japanese(track)
              ? context.l10n.subtitleSimplifiedJapanese
              : context.l10n.subtitleSimplified,
        SubtitleLanguage.traditional =>
          japanese(track)
              ? context.l10n.subtitleTraditionalJapanese
              : context.l10n.subtitleTraditional,
        SubtitleLanguage.japanese => context.l10n.subtitleJapanese,
        SubtitleLanguage.chinese => context.l10n.subtitleChinese,
        SubtitleLanguage.unknown => track.language ?? '',
      };
  bool japanese(SubtitleTrack track) => RegExp(
    r'jpn|japanese|日本語|日语|日語|中日|简日|繁日|簡日|\b(ja|jp)\b',
    caseSensitive: false,
  ).hasMatch('${track.language ?? ''} ${track.title ?? ''}');
  Future<void> importSubtitle() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final loaded = await widget.onImport!();
      if (mounted && loaded) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.l10n.trackSwitchFailed)));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget line(String text) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Text(text, softWrap: false),
  );

  @override
  Widget build(BuildContext context) {
    final subtitles =
        widget.choices ??
        SubtitleChoices.merge(widget.subtitleTracks, const [], const {});
    final audio = {
      for (final t in widget.audioTracks.where((t) => t.id != 'auto')) t.id: t,
    }.values;
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          ListTile(
            title: Text(
              widget.subtitles
                  ? context.l10n.chooseSubtitles
                  : context.l10n.chooseAudio,
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          if (busy) const LinearProgressIndicator(),
          if (widget.subtitles) ...[
            if (widget.onImport != null)
              ListTile(
                leading: const Icon(Icons.file_open_outlined),
                title: Text(context.l10n.importSubtitle),
                onTap: busy ? null : importSubtitle,
              ),
            ListTile(
              key: const ValueKey('subtitle-track-no'),
              title: Text(context.l10n.subtitlesOff),
              selected: widget.selectedId == 'no',
              trailing: widget.selectedId == 'no'
                  ? const Icon(Icons.check, size: 20)
                  : null,
              onTap: busy || widget.onSubtitle == null
                  ? null
                  : () => _select(() => widget.onSubtitle!(SubtitleTrack.no())),
            ),
            for (var i = 0; i < subtitles.length; i++)
              ListTile(
                key: ValueKey('subtitle-track-${subtitles[i].track.id}'),
                title: subtitles[i].filename == null
                    ? Text(context.l10n.trackNumber(i + 1))
                    : line(subtitles[i].filename!),
                subtitle: line(
                  [
                    languageLabel(subtitles[i].track),
                    subtitles[i].format,
                    subtitles[i].external
                        ? context.l10n.externalTrack
                        : context.l10n.containedTrack,
                  ].where((s) => s.isNotEmpty).join(' · '),
                ),
                selected: subtitles[i].aliases.contains(widget.selectedId),
                trailing: subtitles[i].aliases.contains(widget.selectedId)
                    ? const Icon(Icons.check, size: 20)
                    : null,
                onTap: busy || widget.onSubtitle == null
                    ? null
                    : () =>
                          _select(() => widget.onSubtitle!(subtitles[i].track)),
              ),
          ],
          if (!widget.subtitles)
            for (final track in audio)
              ListTile(
                key: ValueKey('audio-track-${track.id}'),
                title: line(_label(track.id, track.title, track.language)),
                subtitle: line(
                  [
                    track.codec,
                    if (track.channelscount != null)
                      '${track.channelscount} ch'
                    else if (track.channels != null &&
                        !track.channels!.startsWith('unknown'))
                      track.channels,
                    if (TrackPreferences.lossless(track))
                      context.l10n.losslessAudio,
                    if (track.samplerate != null) '${track.samplerate} Hz',
                  ].whereType<String>().join(' · '),
                ),
                selected: track.id == widget.selectedId,
                trailing: track.id == widget.selectedId
                    ? const Icon(Icons.check, size: 20)
                    : null,
                onTap: busy || widget.onAudio == null
                    ? null
                    : () => _select(() => widget.onAudio!(track)),
              ),
        ],
      ),
    );
  }
}
