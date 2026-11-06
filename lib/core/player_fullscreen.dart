import 'package:flutter/foundation.dart';

/// App chrome follows the root video fullscreen route, including back/Escape.
final playerFullscreen = ValueNotifier<bool>(false);

class PlayingHeader {
  const PlayingHeader(this.title, this.onBack, {this.videoOverlay = false});
  final bool videoOverlay;
  final String title;
  final VoidCallback onBack;
}

final playingHeader = ValueNotifier<PlayingHeader?>(null);
