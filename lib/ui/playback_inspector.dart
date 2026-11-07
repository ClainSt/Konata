import 'dart:async';
import 'package:flutter/material.dart';
import '../core/playback_probe.dart';
import '../l10n/strings.dart';

class PlaybackInspector extends StatefulWidget {
  const PlaybackInspector({
    super.key,
    required this.probe,
    this.chapterMode = false,
    required this.position,
    required this.onSeek,
    this.onClose,
  });
  final PlaybackProbe probe;
  final bool chapterMode;
  final Duration Function() position;
  final Future<void> Function(Duration) onSeek;
  final VoidCallback? onClose;
  @override
  State<PlaybackInspector> createState() => _PlaybackInspectorState();
}

class _PlaybackInspectorState extends State<PlaybackInspector> {
  List<VideoChapter> chapters = [];
  Map<String, String> stats = {};
  bool busy = true, failed = false;
  Timer? timer;
  bool reading = false;
  @override
  void initState() {
    super.initState();
    refresh();
    if (!widget.chapterMode) {
      timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!reading) refresh();
      });
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> refresh() async {
    if (reading) return;
    reading = true;
    if (mounted) {
      setState(() {
        busy = stats.isEmpty && chapters.isEmpty;
        failed = false;
      });
    }
    try {
      if (widget.chapterMode) {
        final values = await widget.probe.chapters();
        if (mounted) chapters = values;
      } else {
        final values = await widget.probe.statistics();
        if (mounted) stats = values;
      }
    } catch (_) {
      if (mounted) failed = true;
    }
    reading = false;
    if (mounted) setState(() => busy = false);
  }

  String time(Duration duration) =>
      '${duration.inHours.toString().padLeft(2, '0')}:${(duration.inMinutes % 60).toString().padLeft(2, '0')}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}';
  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final baseLabels = [
      l.statVideo,
      l.statResolution,
      l.statResolution,
      l.statFps,
      l.statOutputFps,
      l.statHwdec,
      l.statDropped,
      l.statDecoderDropped,
      l.statAudio,
      l.statSampleRate,
      l.statChannels,
      l.statBitrate,
      l.statCache,
      l.statAvsync,
    ];
    final labels = <String, String>{
      for (var i = 0; i < baseLabels.length; i++)
        PlaybackProbe.properties[i]: baseLabels[i],
      'mpv-version': l.statMpvVersion,
      'hwdec': l.statHwdecSetting,
      'video-params/pixelformat': l.statPixelFormat,
      'video-params/hw-pixelformat': l.statUnderlyingPixelFormat,
      'video-params/colormatrix': l.statColorMatrix,
      'video-params/primaries': l.statColorPrimaries,
      'video-params/gamma': l.statTransferFunction,
      'video-params/colorlevels': l.statColorRange,
      'current-vo': l.statVideoOutput,
      'video-out-params/w': l.statFilteredWidth,
      'video-out-params/h': l.statFilteredHeight,
      'paused-for-cache': l.statCachePaused,
      'decoded-component-depth': l.statSourceDepth,
      'filtered-component-depth': l.statFilteredDepth,
      'target-component-depth': l.statTargetDepth,
      'video-target-params/primaries': l.statTargetPrimaries,
      'video-target-params/gamma': l.statTargetTransfer,
      'presentation-component-depth': l.statPresentationDepth,
      'audio-params/format': l.statDecodedAudioFormat,
      'audio-out-params/format': l.statOutputAudioFormat,
      'audio-out-params/samplerate': l.statOutputSampleRate,
      'audio-out-params/channels': l.statOutputChannels,
      'current-ao': l.statAudioOutput,
      'flutter-texture-size': l.statTextureSize,
    };
    final position = widget.position();
    int? current;
    for (final chapter in chapters) {
      if (chapter.start <= position) current = chapter.index;
    }
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          ListTile(
            title: Text(
              widget.chapterMode ? l.chapters : l.playbackStats,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            trailing: widget.onClose != null
                ? IconButton(
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).closeButtonTooltip,
                    onPressed: widget.onClose,
                    icon: const Icon(Icons.close),
                  )
                : IconButton(
                    tooltip: l.refreshHistory,
                    onPressed: busy ? null : refresh,
                    icon: const Icon(Icons.refresh),
                  ),
          ),
          if (busy) const LinearProgressIndicator(),
          if (failed)
            ListTile(title: Text(l.chapterReadFailed), onTap: refresh),
          if (widget.chapterMode && !busy && !failed && chapters.isEmpty)
            ListTile(title: Text(l.noChapters)),
          if (widget.chapterMode)
            for (final chapter in chapters)
              ListTile(
                selected: chapter.index == current,
                leading: Icon(
                  chapter.index == current
                      ? Icons.play_arrow
                      : Icons.bookmark_outline,
                  size: 20,
                ),
                title: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Text(
                    chapter.title.isEmpty
                        ? '${chapter.index + 1}'
                        : chapter.title,
                    softWrap: false,
                  ),
                ),
                trailing: Text(time(chapter.start)),
                onTap: () async {
                  try {
                    await widget.onSeek(chapter.start);
                    if (context.mounted) Navigator.pop(context);
                  } catch (_) {
                    if (mounted) setState(() => failed = true);
                  }
                },
              ),
          if (!widget.chapterMode)
            for (final property in labels.keys)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 6,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        labels[property]!,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: SelectableText(
                          stats[property] ?? l.statsUnavailable,
                          maxLines: 1,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}
