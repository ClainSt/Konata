import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:konata/application/playback/audio_playback_notifier.dart';
import 'package:konata/domain/playback/cue_and_lrc_parser.dart';
import 'package:konata/presentation/audio/immersive_karaoke_sweep_text.dart';
import 'package:konata/presentation/audio/immersive_lyric_line_leaf.dart';
import 'package:konata/presentation/theme/konata_theme.dart';

class _TestSweepAudioNotifier extends AudioPlaybackNotifier {
  _TestSweepAudioNotifier(AudioPlaybackState seed) : super(initialState: seed);

  void pushState(AudioPlaybackState next) {
    state = next;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('S3 扫白几何缓存、音拍推进与时钟外推停钟验收', () {
    testWidgets('ImmersiveLyricLineLeaf 直接读取原生 line.words 并在句尾与暂停时立即停钟', (
      tester,
    ) async {
      const enhanced = '''
[00:10.00]<00:10.000-00:10.500>光る<00:10.700-00:11.200>なら
[00:10.00]bg:<00:10.200-00:10.900>Ah~
[00:14.00]<00:14.000-00:14.800>次の夜へ
''';
      final doc = LrcParser.parseText(enhanced);
      expect(doc.lines.first.words, hasLength(2));
      expect(doc.lines.first.harmonyWords, hasLength(1));

      late _TestSweepAudioNotifier notifier;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            audioPlaybackProvider.overrideWith(() {
              notifier = _TestSweepAudioNotifier(
                AudioPlaybackState(
                  isActive: true,
                  isPlaying: true,
                  positionSeconds: 10.2,
                  durationSeconds: 180.0,
                  lrcDocument: doc,
                  activeLyricIndex: 0,
                ),
              );
              return notifier;
            }),
          ],
          child: MaterialApp(
            theme: KonataTheme.darkTheme(),
            home: Scaffold(
              body: SizedBox(
                width: 320,
                child: ImmersiveLyricLineLeaf(
                  index: 0,
                  line: doc.lines.first,
                  nextLineStartSeconds: doc.lines[1].startSeconds,
                  secondsPerMora: doc.secondsPerMora,
                  isJapaneseSong: doc.isJapaneseSong,
                  compact: false,
                  userScrolling: false,
                ),
              ),
            ),
          ),
        ),
      );

      // 不传 activeSpanLine 也能自动识别原生主唱与和声逐字片段。
      expect(find.byKey(const ValueKey('active_lead_spans')), findsOneWidget);
      expect(find.byKey(const ValueKey('active_harmony_spans')), findsOneWidget);

      final sweepBefore = tester.widget<ImmersiveKaraokeSweepText>(
        find.byKey(const ValueKey('active_lead_spans')),
      );
      final p0 = sweepBefore.progress.value;
      expect(p0, greaterThan(0.1));
      expect(p0, lessThan(0.3));

      // 推进 300ms：时钟外推平滑前进。
      await tester.pump(const Duration(milliseconds: 300));
      expect(sweepBefore.progress.value, greaterThan(p0 + 0.15));

      // 暂停播放：立即停钟并保持当前进度静止。
      notifier.pushState(
        notifier.state.copyWith(isPlaying: false, positionSeconds: 10.5),
      );
      await tester.pump();
      final pausedVal = sweepBefore.progress.value;
      await tester.pump(const Duration(milliseconds: 500));
      expect(sweepBefore.progress.value, closeTo(pausedVal, 1e-4));

      // 恢复播放并等待自然走完本行（11.2s）：Ticker 到达 1.0 后必须立即停钟（pumpAndSettle 正常收敛不超时）。
      notifier.pushState(
        notifier.state.copyWith(isPlaying: true, positionSeconds: 10.6),
      );
      await tester.pump();
      await tester.pumpAndSettle();
      expect(sweepBefore.progress.value, closeTo(1.0, 1e-4));
    });

    testWidgets('ImmersiveKaraokeSweepText 音拍行级模式多行换行绘制零异常', (tester) async {
      final progress = ValueNotifier<double>(0.0);
      addTearDown(progress.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: KonataTheme.darkTheme(),
          home: Scaffold(
            body: SizedBox(
              width: 240,
              child: ImmersiveKaraokeSweepText(
                text: '無敵の笑顔で荒らすメディア、知りたいその秘密ミステリアス',
                romajiText:
                    'muteki no egao de arasu media shiritai sono himitsu misteriasu',
                isJapaneseSong: true,
                baseStyle: const TextStyle(fontSize: 22, color: Colors.white54),
                litStyle: const TextStyle(fontSize: 22, color: Colors.white),
                progress: progress,
                windowStartSeconds: 10.0,
                windowEndSeconds: 14.5,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final customPaint = tester.widget<CustomPaint>(
        find.descendant(
          of: find.byType(ImmersiveKaraokeSweepText),
          matching: find.byType(CustomPaint),
        ),
      );
      final painter = customPaint.foregroundPainter!;
      final size = tester.getSize(find.byType(ImmersiveKaraokeSweepText));

      for (final p in <double>[0.0, 0.25, 0.5, 0.75, 1.0]) {
        progress.value = p;
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        painter.paint(canvas, size);
        final pic = recorder.endRecording();
        pic.dispose();
      }
      expect(size.height, greaterThan(40.0));
    });
  });
}
