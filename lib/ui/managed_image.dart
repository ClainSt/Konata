import 'dart:ui' as ui;
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../core/image_store.dart';
import '../core/metadata_servers.dart';

enum ManagedArtwork { poster, still, backdrop }

typedef ManagedImageKey = ({String url, String? owner, int? displayWidth});

/// Reuses decoded frames across routes for the same work. Different owners need
/// separate completers so cancelling one does not fail another's live image.
class ManagedImageProvider extends ImageProvider<ManagedImageKey> {
  const ManagedImageProvider(this.url, {this.owner, this.displayWidth});
  final String url;
  final String? owner;
  final int? displayWidth;
  @override
  Future<ManagedImageKey> obtainKey(ImageConfiguration configuration) {
    if (owner != null && url.startsWith('http')) {
      // Keep synchronous decoded-cache hits during Hero flights. Cache misses
      // also await ownership inside ImageStore.load before writing artwork.
      unawaited(
        ImageStore.retain(owner!, [
          url,
        ], displayWidth: displayWidth).catchError((Object _) {}),
      );
    }
    return SynchronousFuture((
      url: url,
      owner: owner,
      displayWidth: displayWidth,
    ));
  }

  @override
  ImageStreamCompleter loadImage(
    ManagedImageKey key,
    ImageDecoderCallback decode,
  ) => MultiFrameImageStreamCompleter(
    codec: _decode(key, decode),
    scale: 1,
    debugLabel: key.url,
  );
  Future<ui.Codec> _decode(
    ManagedImageKey key,
    ImageDecoderCallback decode,
  ) async {
    try {
      final bytes = await ImageStore.load(
        key.url,
        owner: key.owner,
        displayWidth: key.displayWidth,
      );
      return await decode(await ui.ImmutableBuffer.fromUint8List(bytes));
    } catch (_) {
      PaintingBinding.instance.imageCache.evict(key);
      rethrow;
    }
  }
}

class ManagedImage extends StatelessWidget {
  const ManagedImage(
    this.url, {
    super.key,
    this.width,
    this.height,
    this.fit,
    this.alignment = Alignment.center,
    this.errorBuilder,
    this.frameBuilder,
    this.owner,
    this.decodeWidth = 1024,
    this.artwork = ManagedArtwork.poster,
  });
  final String url;
  final String? owner;
  final int decodeWidth;
  final ManagedArtwork artwork;
  final double? width, height;
  final BoxFit? fit;
  final AlignmentGeometry alignment;
  final ImageErrorWidgetBuilder? errorBuilder;
  final ImageFrameBuilder? frameBuilder;
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final physicalWidth =
            ((width ??
                        (constraints.hasBoundedWidth
                            ? constraints.maxWidth
                            : 640)) *
                    MediaQuery.devicePixelRatioOf(context))
                .ceil()
                .clamp(1, 8192);
        final source = ImageStore.tmdbDisplayUrl(
          url,
          physicalWidth,
          backdrop: artwork == ManagedArtwork.backdrop,
          poster: artwork == ManagedArtwork.poster,
        );
        final target = artwork == ManagedArtwork.poster
            ? physicalWidth.clamp(1, decodeWidth)
            : physicalWidth;
        final bangumiWidth =
            artwork == ManagedArtwork.poster &&
                MetadataServers.imageResource(url)?.$1 == 3
            ? target <= 185
                  ? 185
                  : target <= 342
                  ? 342
                  : 500
            : null;
        return _image(source, target, displayWidth: bangumiWidth);
      },
    );
  }

  Widget _image(String source, int targetWidth, {int? displayWidth}) => Image(
    image: ResizeImage(
      ManagedImageProvider(source, owner: owner, displayWidth: displayWidth),
      width: targetWidth,
      policy: ResizeImagePolicy.fit,
    ),
    width: width,
    height: height,
    fit: fit,
    alignment: alignment,
    gaplessPlayback: true,
    frameBuilder: frameBuilder,
    errorBuilder:
        errorBuilder ?? (_, _, _) => const Icon(Icons.broken_image_outlined),
  );
}
