import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../core/playback_probe.dart';

class TimelinePreview extends StatefulWidget {
  const TimelinePreview({
    super.key,
    required this.duration,
    required this.fraction,
    required this.width,
    required this.chapters,
    required this.loadFrame,
  });
  final Duration duration;
  final double? fraction;
  final double width;
  final List<VideoChapter> chapters;
  final Future<Uint8List?> Function(Duration) loadFrame;
  @override
  State<TimelinePreview> createState() => _TimelinePreviewState();
}

class _TimelinePreviewState extends State<TimelinePreview> {
  Timer? timer;
  int generation = 0;
  Uint8List? bytes;
  Duration target = Duration.zero;
  String chapterName = '';
  @override
  void initState() {
    super.initState();
    schedule();
  }

  @override
  void didUpdateWidget(TimelinePreview old) {
    super.didUpdateWidget(old);
    if (old.fraction != widget.fraction ||
        old.chapters != widget.chapters ||
        old.duration != widget.duration ||
        old.width != widget.width) {
      schedule();
    }
  }

  void schedule() {
    timer?.cancel();
    final sequence = ++generation;
    bytes = null;
    if (widget.fraction == null || widget.duration <= Duration.zero) return;
    target = widget.duration * widget.fraction!.clamp(0, 1);
    VideoChapter? current;
    for (final chapter in widget.chapters) {
      if (chapter.start <= target) current = chapter;
      final distance =
          (chapter.start - target).inMilliseconds.abs() /
          widget.duration.inMilliseconds *
          widget.width;
      if (distance <= 8) {
        target = chapter.start;
        current = chapter;
        break;
      }
    }
    chapterName = current?.title ?? '';
    final requested = target;
    timer = Timer(const Duration(milliseconds: 200), () async {
      Uint8List? image;
      try {
        image = await widget.loadFrame(requested);
      } catch (_) {
        /* Optional preview. */
      }
      if (mounted && generation == sequence) setState(() => bytes = image);
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    generation++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.duration.inMilliseconds;
    final width = math.min(280.0, widget.width);
    final time =
        '${target.inMinutes.toString().padLeft(2, '0')}:${(target.inSeconds % 60).toString().padLeft(2, '0')}';
    Widget label(String text) => ColoredBox(
      color: Colors.black87,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Text(
            text,
            softWrap: false,
            style: const TextStyle(color: Colors.white, fontSize: 14),
          ),
        ),
      ),
    );
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.centerLeft,
      children: [
        if (total > 0)
          for (final chapter in widget.chapters)
            Positioned(
              left:
                  (chapter.start.inMilliseconds / total).clamp(0, 1) *
                      widget.width -
                  4,
              child: Transform.rotate(
                angle: math.pi / 4,
                child: const SizedBox(
                  width: 8,
                  height: 8,
                  child: ColoredBox(color: Colors.white70),
                ),
              ),
            ),
        if (widget.fraction != null && total > 0)
          Positioned(
            left: (widget.fraction! * widget.width - width / 2).clamp(
              0,
              math.max(0, widget.width - width),
            ),
            bottom: 32,
            width: width,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (chapterName.isNotEmpty) label(chapterName),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: bytes == null
                        ? const ColoredBox(
                            color: Colors.black87,
                            child: Icon(
                              Icons.image_outlined,
                              color: Colors.white54,
                            ),
                          )
                        : Image.memory(
                            bytes!,
                            fit: BoxFit.contain,
                            gaplessPlayback: false,
                          ),
                  ),
                ),
                label(time),
              ],
            ),
          ),
      ],
    );
  }
}
