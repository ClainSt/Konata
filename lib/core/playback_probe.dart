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
    'ffmpeg-version',
    'video-format',
    'video-dec-params/pixelformat',
    'video-dec-params/hw-pixelformat',
    'video-out-params/pixelformat',
    'video-out-params/hw-pixelformat',
    'video-target-params/pixelformat',
    'video-target-params/primaries',
    'video-target-params/gamma',
    'audio-params/format',
    'audio-params/channels',
    'audio-out-params/format',
    'audio-out-params/samplerate',
    'audio-out-params/channels',
    'current-ao',
  ];
  static int? componentDepth(String? format) {
    // Recognize component precision, never average bpp or opaque surfaces.
    format = format?.toLowerCase();
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
    if (format == null) return null;
    final planar = RegExp(
      r'^(?:yuva?(?:420|422|444)p|gbra?p|gray)(9|10|12|14|16)(?:msb)?(?:le|be)?$',
    ).firstMatch(format);
    if (planar != null) return int.parse(planar.group(1)!);
    final semiplanar = RegExp(
      r'^p[024](10|12|16)(?:le|be)?$',
    ).firstMatch(format);
    if (semiplanar != null) return int.parse(semiplanar.group(1)!);
    if (RegExp(r'^(?:rgb48|bgr48|rgba64|bgra64)(?:le|be)?$').hasMatch(format)) {
      return 16;
    }
    return null;
  }

  /// Demuxer pixel format of the selected video track, before hwdec conversion.
  Future<Map<String, String>> sourceVideoParameters() async {
    try {
      final count = int.tryParse(await read('track-list/count')) ?? 0;
      for (var i = 0; i < count.clamp(0, 128); i++) {
        if (await read('track-list/$i/type') == 'video' &&
            await read('track-list/$i/selected') == 'yes') {
          final result = <String, String>{};
          for (final key in [
            'codec',
            'format-name',
            'codec-profile',
            'dolby-vision-profile',
          ]) {
            try {
              final value = await read('track-list/$i/$key');
              if (value.isNotEmpty) result[key] = value;
            } catch (_) {
              // An unavailable field must not hide the remaining source data.
            }
          }
          return result;
        }
      }
    } catch (_) {
      // Unknown source precision must stay unknown.
    }
    return {};
  }

  static bool losesPrecision(String? source, String? decoded) {
    final sourceDepth = componentDepth(source);
    final decodedDepth = componentDepth(decoded);
    return sourceDepth != null &&
        decodedDepth != null &&
        decodedDepth < sourceDepth;
  }

  static bool unsupportedMediaCodecProfile(String prefix, String message) =>
      prefix == 'ffmpeg/video' &&
      message.contains('_mediacodec: Unsupported or unknown profile');

  static bool needsPrecisionFallback({
    String? sourceCodec,
    String? sourceFormat,
    String? sourceProfile,
    String? decodedFormat,
  }) {
    if (componentDepth(sourceFormat) != null) {
      return losesPrecision(sourceFormat, decodedFormat);
    }
    // A high-bit-depth profile is a conservative policy signal, not proof of
    // encoded bit depth when the demuxer omits the pixel format.
    // AV1 Main includes both 8 and 10 bit. With unknown source precision, an
    // 8-bit copy cannot establish fidelity; prefer software until it is known.
    return componentDepth(decodedFormat) == 8 &&
        (sourceCodec?.toLowerCase() == 'av1' ||
            const {
              'main 10',
              'high 10',
              'high 10 intra',
              'rext',
            }.contains(sourceProfile?.toLowerCase()));
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
    final source = await sourceVideoParameters();
    final sourceFormat = source['format-name'];
    if (source.containsKey('codec-profile')) {
      values['source-video-profile'] = source['codec-profile']!;
    }
    if (sourceFormat != null) {
      values['source-video-format'] = sourceFormat;
      final depth = componentDepth(sourceFormat);
      if (depth != null) values['source-component-depth'] = '$depth';
    }
    // mpv video-params describes decoded frames, not the encoded source.
    // A Main10 copy path may already have become 8-bit here. Neither these
    // values nor video-target-params prove the OS compositor/panel precision.
    for (final stage in {
      'decoded': values.containsKey('video-dec-params/pixelformat')
          ? 'video-dec-params'
          : 'video-params',
      'filtered': 'video-out-params',
      'target': 'video-target-params',
    }.entries) {
      final depth =
          componentDepth(values['${stage.value}/hw-pixelformat']) ??
          componentDepth(values['${stage.value}/pixelformat']);
      if (depth != null) values['${stage.key}-component-depth'] = '$depth';
    }
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
