import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccplayer/ui/app_header.dart';

void main() {
  testWidgets(
    'playback title replaces tabs, ellipsizes and retains right actions',
    (tester) async {
      var backed = false;
      const title =
          'Very long video filename with original release tags and episode information.mkv';
      await tester.binding.setSurfaceSize(const Size(800, 400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppHeader(
              showSources: false,
              mobile: false,
              playbackTitle: title,
              onPlaybackBack: () => backed = true,
              onNavigate: (_) {},
              onSettings: () {},
            ),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('nav-library')), findsNothing);
      expect(find.byKey(const ValueKey('toggle-theme')), findsOneWidget);
      expect(find.byKey(const ValueKey('open-settings')), findsOneWidget);
      expect(
        tester.widget<Text>(find.text(title)).overflow,
        TextOverflow.ellipsis,
      );
      expect(find.byTooltip(title), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('playback-header-back')));
      expect(backed, true);
      expect(tester.takeException(), isNull);
    },
  );
}
