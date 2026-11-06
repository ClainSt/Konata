class VideoChapter {
  const VideoChapter(this.index, this.start, this.title);
  final int index;
  final Duration start;
  final String title;
}

/// Reads native mpv properties independently; missing stats never block others.
class PlaybackProbe {
  const PlaybackProbe(this.read, {this.textureResolution});
  final Future<String> Function(String) read;
  final String? Function()? textureResolution;
  Future<List<VideoChapter>> chapters() async {
    final count = int.tryParse(await read('chapter-list/count')) ?? 0;
    final result = <VideoChapter>[];
    for (var i = 0; i < count.clamp(0, 10000); i++) {
      final seconds = double.tryParse(await read('chapter-list/$i/time'));
      if (seconds == null || !seconds.isFinite) continue;
      // Container chapters can start before the first presentable video PTS.
      if (seconds < 0 && i != 0) continue;
      String title;
      try {
        title = await read('chapter-list/$i/title');
      } catch (_) {
        title = '';
      }
      result.add(
        VideoChapter(
          i,
          seconds < 0
              ? Duration.zero
              : Duration(microseconds: (seconds * 1000000).round()),
          title,
        ),
      );
    }
    return result;
  }

  static const properties = [
    'video-codec',
    'video-params/w',
    'video-params/h',
    'container-fps',
    'estimated-vf-fps',
    'hwdec-current',
    'frame-drop-count',
    'decoder-frame-drop-count',
    'audio-codec-name',
    'audio-params/samplerate',
    'audio-params/channel-count',
    'audio-bitrate',
    'demuxer-cache-duration',
    'avsync',
    'mpv-version',
    'hwdec',
    'video-params/pixelformat',
    'video-params/hw-pixelformat',
    'video-params/colormatrix',
    'video-params/primaries',
    'video-params/gamma',
    'video-params/colorlevels',
    'current-vo',
    'video-out-params/w',
    'video-out-params/h',
    'paused-for-cache',
  ];
  static int? componentDepth(String? format) {
    if (const {
      'yuv420p',
      'yuv422p',
      'yuv444p',
      'nv12',
      'nv21',
      'bgra',
      'rgba',
    }.contains(format)) {
      return 8;
    }
    if (const {
      'yuv420p10',
      'yuv422p10',
      'yuv444p10',
      'p010',
      'yuv420p10le',
      'yuv420p10be',
      'yuv422p10le',
      'yuv422p10be',
      'yuv444p10le',
      'yuv444p10be',
      'p010le',
      'p010be',
    }.contains(format)) {
      return 10;
    }
    return null;
  }

  Future<Map<String, String>> statistics() async {
    final values = <String, String>{};
    for (final property in properties) {
      try {
        final value = await read(property);
        if (value.isNotEmpty) values[property] = value;
      } catch (_) {
        /* Unavailable on some outputs. */
      }
    }
    final depth =
        componentDepth(values['video-params/hw-pixelformat']) ??
        componentDepth(values['video-params/pixelformat']);
    if (depth != null) values['source-component-depth'] = '$depth';
    try {
      final texture = textureResolution?.call();
      if (texture != null && texture.isNotEmpty) {
        values['flutter-texture-size'] = texture;
      }
    } catch (_) {
      /* Texture may already be disposed. */
    }
    return values;
  }
}
