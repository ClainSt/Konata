import 'package:flutter/material.dart';
import '../core/image_store.dart';

class ManagedImage extends StatefulWidget {
  const ManagedImage(
    this.url, {
    super.key,
    this.width,
    this.height,
    this.fit,
    this.alignment = Alignment.center,
    this.errorBuilder,
  });
  final String url;
  final double? width, height;
  final BoxFit? fit;
  final AlignmentGeometry alignment;
  final ImageErrorWidgetBuilder? errorBuilder;
  @override
  State<ManagedImage> createState() => _ManagedImageState();
}

class _ManagedImageState extends State<ManagedImage> {
  late Future<dynamic> data;
  @override
  void initState() {
    super.initState();
    data = ImageStore.load(widget.url);
  }

  @override
  void didUpdateWidget(ManagedImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) data = ImageStore.load(widget.url);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<dynamic>(
    future: data,
    builder: (context, snapshot) {
      if (snapshot.hasData) {
        return Image.memory(
          snapshot.data,
          width: widget.width,
          height: widget.height,
          fit: widget.fit,
          alignment: widget.alignment,
          errorBuilder: widget.errorBuilder,
          gaplessPlayback: true,
        );
      }
      if (snapshot.hasError) {
        return widget.errorBuilder?.call(
              context,
              snapshot.error!,
              snapshot.stackTrace,
            ) ??
            const Icon(Icons.broken_image_outlined);
      }
      return SizedBox(
        width: widget.width,
        height: widget.height,
        child: const Center(child: Icon(Icons.image_outlined)),
      );
    },
  );
}
