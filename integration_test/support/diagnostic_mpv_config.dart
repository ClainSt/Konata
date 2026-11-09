import 'dart:io';

import 'package:ccplayer/core/mpv_config_store.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

// Explicit decoder controls belong to controlled experiments, not app settings.
enum VideoDecodeMode { automatic, hardwarePreferred, software, custom }

class DiagnosticMpvConfigStore extends MpvConfigStore {
  DiagnosticMpvConfigStore({required super.rootOverride});
  VideoDecodeMode decodeMode = VideoDecodeMode.automatic;

  Future<void> setDecodeMode(VideoDecodeMode mode) async => decodeMode = mode;

  @override
  VideoControllerConfiguration get videoConfiguration =>
      VideoControllerConfiguration(
        hwdec: switch (decodeMode) {
          VideoDecodeMode.software => 'no',
          VideoDecodeMode.hardwarePreferred =>
            Platform.isAndroid ? 'auto-safe' : 'auto',
          _ => null,
        },
      );

  @override
  PlayerConfiguration configurationFor(Directory? profile) =>
      PlayerConfiguration(
        logLevel: MPVLogLevel.warn,
        libass: Platform.isWindows || Platform.isAndroid,
        mpvConfigurationDirectory: profile?.path,
        mpvRespectRenderingConfiguration:
            profile != null && decodeMode == VideoDecodeMode.custom,
      );
}
