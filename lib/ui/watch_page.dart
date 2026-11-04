import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;
import '../core/catalog.dart';
import '../core/sources.dart';
import 'nipaplay_style.dart';

class WatchPage extends StatefulWidget {
  const WatchPage({super.key, required this.asset});
  final Map<String, Object?> asset;
  @override
  State<WatchPage> createState() => _WatchPageState();
}

class _WatchPageState extends State<WatchPage> {
  late final Player player;
  late final VideoController controller;
  StreamSubscription<Duration>? _positionSubscription;
  Timer? _saver;
  bool loading = true;
  String? error;
  List<SubtitleTrack> addedSubtitles = [];
  Duration current = Duration.zero;
  Duration total = Duration.zero;

  @override
  void initState() {
    super.initState();
    player = Player();
    controller = VideoController(player);
    _positionSubscription = player.stream.position.listen((v) {
      current = v;
    });
    _saver = Timer.periodic(const Duration(seconds: 5), (_) => _save());
    _open();
  }

  Future<void> _open() async {
    try {
      final asset = widget.asset;
      final source = Catalog.instance.sourceOf(asset['source_id'].toString());
      final relative = asset['relative_path'].toString();
      final uri = source['kind'] == 'local'
          ? p.join(
              source['location'].toString(),
              relative.replaceAll('/', Platform.pathSeparator),
            )
          : (await StreamBroker.instance.issue(source, relative)).toString();
      await player.open(Media(uri));
      final saved = await Catalog.instance.resumePosition(
        asset['id'].toString(),
      );
      if (saved > 0) await player.seek(Duration(milliseconds: saved));
      final subtitleFiles = await StreamBroker.instance.subtitles(
        source,
        relative,
      );
      final tracks = <SubtitleTrack>[];
      for (final subtitle in subtitleFiles) {
        final target = source['kind'] == 'local'
            ? p.join(
                source['location'].toString(),
                subtitle.replaceAll('/', Platform.pathSeparator),
              )
            : (await StreamBroker.instance.issue(source, subtitle)).toString();
        tracks.add(SubtitleTrack.uri(target, title: p.basename(subtitle)));
      }
      addedSubtitles = tracks;
      if (tracks.isNotEmpty) await player.setSubtitleTrack(tracks.first);
      if (mounted) setState(() => loading = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e.toString();
          loading = false;
        });
      }
    }
  }

  Future<void> _save() async {
    final duration = player.state.duration;
    if (duration > Duration.zero) {
      await Catalog.instance.progress(
        widget.asset['id'].toString(),
        current.inMilliseconds,
        duration.inMilliseconds,
      );
    }
  }

  @override
  void dispose() {
    _saver?.cancel();
    _positionSubscription?.cancel();
    unawaited(_save().then((_) => player.dispose()));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selectedAudio = player.state.track.audio;
    final selectedSub = player.state.track.subtitle;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.asset['name'].toString(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: '音轨',
            icon: const Icon(Icons.graphic_eq),
            onPressed: () => _tracks(false, selectedAudio.id, selectedSub.id),
          ),
          IconButton(
            tooltip: '字幕',
            icon: const Icon(Icons.subtitles),
            onPressed: () => _tracks(true, selectedAudio.id, selectedSub.id),
          ),
        ],
      ),
      body: error != null
          ? Center(child: Text('无法播放：$error'))
          : loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: Center(
                    child: MaterialDesktopVideoControlsTheme(
                      normal: MaterialDesktopVideoControlsThemeData(
                        seekBarPositionColor: NipaPlayStyle.accent,
                        seekBarThumbColor: NipaPlayStyle.accent,
                      ),
                      fullscreen: MaterialDesktopVideoControlsThemeData(
                        seekBarPositionColor: NipaPlayStyle.accent,
                        seekBarThumbColor: NipaPlayStyle.accent,
                      ),
                      child: MaterialVideoControlsTheme(
                        normal: MaterialVideoControlsThemeData(
                          seekBarPositionColor: NipaPlayStyle.accent,
                          seekBarThumbColor: NipaPlayStyle.accent,
                        ),
                        fullscreen: MaterialVideoControlsThemeData(
                          seekBarPositionColor: NipaPlayStyle.accent,
                          seekBarThumbColor: NipaPlayStyle.accent,
                        ),
                        child: Video(
                          controller: controller,
                          controls: AdaptiveVideoControls,
                        ),
                      ),
                    ),
                  ),
                ),
                StreamBuilder<Duration>(
                  stream: player.stream.position,
                  builder: (context, snapshot) {
                    final pos = snapshot.data ?? Duration.zero;
                    final max = player.state.duration;
                    return Column(
                      children: [
                        Slider(
                          value: pos.inMilliseconds.toDouble().clamp(
                            0,
                            max.inMilliseconds > 0
                                ? max.inMilliseconds.toDouble()
                                : 1.0,
                          ),
                          max: max.inMilliseconds > 0
                              ? max.inMilliseconds.toDouble()
                              : 1.0,
                          onChanged: (value) => player.seek(
                            Duration(milliseconds: value.round()),
                          ),
                        ),
                        Row(
                          children: [
                            IconButton(
                              icon: const Icon(Icons.replay_10),
                              onPressed: () => player.seek(
                                pos - const Duration(seconds: 10),
                              ),
                            ),
                            StreamBuilder<bool>(
                              stream: player.stream.playing,
                              builder: (context, playing) => IconButton(
                                icon: Icon(
                                  (playing.data ?? false)
                                      ? Icons.pause
                                      : Icons.play_arrow,
                                ),
                                onPressed: () => player.playOrPause(),
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.forward_10),
                              onPressed: () => player.seek(
                                pos + const Duration(seconds: 10),
                              ),
                            ),
                            const Spacer(),
                            Text('${_format(pos)} / ${_format(max)}'),
                            const SizedBox(width: 14),
                          ],
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
    );
  }

  String _format(Duration d) =>
      '${d.inHours.toString().padLeft(2, '0')}:${(d.inMinutes % 60).toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  void _tracks(bool subtitles, String audioId, String subId) {
    final list = subtitles
        ? <SubtitleTrack>[
            SubtitleTrack.no(),
            ...player.state.tracks.subtitle,
            ...addedSubtitles,
          ]
        : <SubtitleTrack>[];
    final audios = subtitles
        ? <AudioTrack>[]
        : [AudioTrack.auto(), ...player.state.tracks.audio];
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: Text(
                subtitles ? '选择字幕' : '选择音轨',
                style: Theme.of(ctx).textTheme.titleLarge,
              ),
            ),
            if (subtitles)
              for (final track in list)
                ListTile(
                  title: Text(
                    track.title ??
                        (track.id == 'no'
                            ? '关闭字幕'
                            : track.language ?? track.id),
                  ),
                  subtitle: Text(track.codec ?? ''),
                  selected: track.id == subId,
                  onTap: () {
                    player.setSubtitleTrack(track);
                    Navigator.pop(ctx);
                  },
                ),
            if (!subtitles)
              for (final track in audios)
                ListTile(
                  title: Text(track.title ?? track.language ?? track.id),
                  subtitle: Text(
                    [
                      track.codec,
                      track.channels,
                      track.samplerate?.toString(),
                    ].whereType<String>().join(' · '),
                  ),
                  selected: track.id == audioId,
                  onTap: () {
                    player.setAudioTrack(track);
                    Navigator.pop(ctx);
                  },
                ),
          ],
        ),
      ),
    );
  }
}
