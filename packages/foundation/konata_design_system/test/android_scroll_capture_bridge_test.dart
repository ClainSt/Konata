import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata_design_system/konata_design_system.dart';

void main() {
  testWidgets('系统长截图实时查询当前路由，滚动切片后恢复原位置', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(390, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final navigator = GlobalKey<NavigatorState>();
    final scroll = ScrollController(initialScrollOffset: 180);
    addTearDown(scroll.dispose);
    const channel = MethodChannel('konata/scroll_capture');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final updates = <Map<Object?, Object?>>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'updateScrollTarget') {
        updates.add(call.arguments as Map<Object?, Object?>);
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    Future<Object?> call(String method, [Object? arguments]) async {
      final result = Completer<ByteData?>();
      await messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall(method, arguments),
        ),
        result.complete,
      );
      final response = await result.future;
      return response == null
          ? null
          : const StandardMethodCodec().decodeEnvelope(response);
    }

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        builder: (_, child) =>
            AndroidScrollCaptureScope(navigatorKey: navigator, child: child!),
        home: const Scaffold(body: Center(child: Text('首页'))),
      ),
    );
    await tester.pumpAndSettle();
    expect(await call('queryScrollTarget'), {'ready': false});
    unawaited(
      navigator.currentState!.push<void>(
        MaterialPageRoute(
          builder: (_) => Scaffold(
            body: SingleChildScrollView(
              controller: scroll,
              child: const SizedBox(height: 2400, width: 390),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(updates.last['hasTarget'], isTrue);
    final target = await call('queryScrollTarget') as Map<Object?, Object?>;
    expect(target['ready'], isTrue);
    expect(
      (target['bottomPx'] as int) - (target['topPx'] as int),
      greaterThan(120),
    );
    expect((await call('beginCapture') as Map)['ready'], isTrue);

    final capture = call('scrollToCaptureArea', {'requestedTopPx': 300});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final result = await capture as Map;
    expect(result['ok'], isTrue);
    expect(result['actualDeltaPx'], 300);
    expect(scroll.offset, 480);

    final end = call('endCapture');
    await tester.pump();
    await end;
    expect(scroll.offset, 180);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(await call('queryScrollTarget'), {'ready': false});
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
