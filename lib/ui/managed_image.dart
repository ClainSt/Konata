import 'dart:ui' as ui;
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../core/image_store.dart';

enum ManagedArtwork { poster, still, backdrop }

typedef ManagedImageKey = ({String url, String? owner});

/// Reuses decoded frames across routes for the same work. Different owners need
/// separate completers so cancelling one does not fail another's live image.
class ManagedImageProvider extends ImageProvider<ManagedImageKey> {
  const ManagedImageProvider(this.url, {this.owner});
  final String url;
  final String? owner;
  @override
  Future<ManagedImageKey> obtainKey(ImageConfiguration configuration) {
    if (owner != null && url.startsWith('http')) {
      // Keep synchronous decoded-cache hits during Hero flights. Cache misses
      // also await ownership inside ImageStore.load before writing artwork.
      unawaited(ImageStore.retain(owner!, [url]).catchError((Object _) {}));
    }
    return SynchronousFuture((url: url, owner: owner));
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
      final bytes = await ImageStore.load(key.url, owner: key.owner);
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
  @override
  Widget build(BuildContext context) {
    if (artwork == ManagedArtwork.poster) return _image(url, decodeWidth);
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
        );
        return _image(source, physicalWidth);
      },
    );
  }

  Widget _image(String source, int targetWidth) => Image(
    image: ResizeImage(
      ManagedImageProvider(source, owner: owner),
      width: targetWidth,
      policy: ResizeImagePolicy.fit,
    ),
    width: width,
    height: height,
    fit: fit,
    alignment: alignment,
    gaplessPlayback: true,
    errorBuilder:
        errorBuilder ?? (_, _, _) => const Icon(Icons.broken_image_outlined),
  );
}
