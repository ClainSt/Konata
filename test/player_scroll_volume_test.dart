import 'package:ccplayer/ui/player_scroll_volume.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'wheel uses scrollDelta, clamps volume and ignores horizontal scroll',
    (tester) async {
      var volume = 50.0;
      var writes = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerScrollVolume(
            volume: () => volume,
            onChanged: (value) async {
              volume = value;
              writes++;
            },
            child: const SizedBox.expand(),
          ),
        ),
      );
      Future<void> wheel(Offset delta) => tester.sendEventToBinding(
        PointerScrollEvent(
          position: const Offset(100, 100),
          scrollDelta: delta,
        ),
      );
      await wheel(const Offset(0, -120));
      expect(volume, 55);
      await wheel(const Offset(0, 120));
      expect(volume, 50);
      volume = 98;
      await wheel(const Offset(0, -120));
      expect(volume, 100);
      volume = 2;
      await wheel(const Offset(0, 120));
      expect(volume, 0);
      await wheel(const Offset(120, 0));
      expect(writes, 4);
      expect(tester.takeException(), isNull);
    },
  );
}
