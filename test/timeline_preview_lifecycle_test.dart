import 'dart:async';
import 'dart:convert';

import 'package:ccplayer/ui/timeline_preview.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final remove in [false, true]) {
    testWidgets(
      'decoded preview cache is evicted when ${remove ? 'removed' : 'hidden'}',
      (tester) async {
        final bytes = base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
        );
        final provider = MemoryImage(bytes);
        Future<void> show(double? fraction) => tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: SizedBox(
                width: 300,
                height: 36,
                child: TimelinePreview(
                  duration: const Duration(seconds: 10),
                  fraction: fraction,
                  width: 300,
                  chapters: const [],
                  loadFrame: (_) async => bytes,
                ),
              ),
            ),
          ),
        );
        await show(.1);
        await tester.pump(const Duration(milliseconds: 220));
        await tester.pump();
        await tester.runAsync(() async {
          final loaded = Completer<void>();
          final stream = provider.resolve(ImageConfiguration.empty);
          final listener = ImageStreamListener(
            (info, _) {
              info.dispose();
              if (!loaded.isCompleted) loaded.complete();
            },
            onError: (Object error, StackTrace? stack) {
              if (!loaded.isCompleted) loaded.completeError(error, stack);
            },
          );
          stream.addListener(listener);
          try {
            await loaded.future;
          } finally {
            stream.removeListener(listener);
          }
        });
        expect(
          PaintingBinding.instance.imageCache.containsKey(provider),
          isTrue,
        );
        if (remove) {
          await tester.pumpWidget(const SizedBox());
        } else {
          await show(null);
        }
        await tester.pump();
        expect(
          PaintingBinding.instance.imageCache.containsKey(provider),
          isFalse,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
