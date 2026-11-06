import 'dart:async';
import 'package:ccplayer/ui/player_volume_control.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'volume slider stays visible, reflects changes and restores mute',
    (tester) async {
      final volume = StreamController<double>.broadcast();
      addTearDown(volume.close);
      double latest = 35;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlayerVolumeControl(
              volume: volume.stream,
              initialVolume: latest,
              onChanged: (value) async {
                latest = value;
                volume.add(value);
              },
            ),
          ),
        ),
      );
      expect(tester.widget<Slider>(find.byType(Slider)).value, 35);
      await tester.tap(find.byType(IconButton));
      await tester.pump();
      expect(latest, 0);
      expect(find.byType(Slider), findsOneWidget);
      await tester.tap(find.byType(IconButton));
      await tester.pump();
      expect(latest, 35);
      volume.add(80);
      await tester.pump();
      expect(tester.widget<Slider>(find.byType(Slider)).value, 80);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
