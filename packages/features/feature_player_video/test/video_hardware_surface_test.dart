import 'dart:async';

import 'package:engine_playback/engine_playback.dart';
import 'package:feature_player_video/feature_player_video.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';

import 'support/video_test_harness.dart';

typedef Viewport = ({Rect rect, double radius});

class _AndroidSurfaceSpy implements AndroidVideoSurfacePort {
  final changes = StreamController<AndroidSurfaceDescriptor?>.broadcast();
  final events = <Viewport?>[];
  bool disposed = false;

  @override
  AndroidSurfaceDescriptor? get current => null;
  @override
  Stream<AndroidSurfaceDescriptor?> get surfaceChanges => changes.stream;
  @override
  bool get isDisposed => disposed;
  @override
  Future<void> syncViewportRect({
    required int leftPx,
    required int topPx,
    required int rightPx,
    required int bottomPx,
    double cornerRadiusPx = 0,
  }) async {
    events.add((
      rect: Rect.fromLTRB(
        leftPx.toDouble(),
        topPx.toDouble(),
        rightPx.toDouble(),
        bottomPx.toDouble(),
      ),
      radius: cornerRadiusPx,
    ));
  }

  @override
  Future<void> hideViewport() async {
    events.add(null);
  }

  @override
  Future<AndroidSurfaceDescriptor?> queryCurrent() async => current;
  @override
  Future<void> releaseReference(int wid) async {}
  @override
  Future<void> releaseSurface() async {}
  @override
  Future<void> detachWithoutClearingChannel() => dispose();
  @override
  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    await changes.close();
  }
}

class _DesktopSurfaceSpy implements KonataVideoTextureBridge {
  final changes = StreamController<NativeTextureChangedEvent>.broadcast();
  final events = <Viewport?>[];
  int created = 0;

  @override
  Stream<NativeTextureChangedEvent> get textureChanges => changes.stream;
  @override
  Future<NativeVideoSessionHandle> createSession({
    required int mpvHandleAddress,
    int width = 1280,
    int height = 720,
    bool preferSoftware = false,
    String renderBackend = 'gpu_next',
  }) async {
    created++;
    return const NativeVideoSessionHandle(
      sessionId: 1,
      textureId: -1,
      backend: 'd3d11',
      adapterName: '测试适配器',
      underlaySwapChainActive: true,
    );
  }

  @override
  Future<void> resize({
    required int sessionId,
    required int width,
    required int height,
  }) async {}
  @override
  Future<void> setViewportRect({
    required int sessionId,
    required int leftPx,
    required int topPx,
    required int rightPx,
    required int bottomPx,
    double cornerRadiusPx = 0,
    bool visible = true,
  }) async {
    expect(sessionId, 1);
    events.add(
      visible
          ? (
              rect: Rect.fromLTRB(
                leftPx.toDouble(),
                topPx.toDouble(),
                rightPx.toDouble(),
                bottomPx.toDouble(),
              ),
              radius: cornerRadiusPx,
            )
          : null,
    );
  }

  @override
  Future<NativeSessionMetrics?> getSessionMetrics(int sessionId) async => null;
  @override
  Future<bool> setHdrFboEnabled({
    required int sessionId,
    required bool enabled,
  }) async => true;
  @override
  Future<void> disposeSession(int sessionId) async {}
  @override
  Future<({bool available, String adapterName})> getAdapterInfo() async =>
      (available: true, adapterName: '测试适配器');
  @override
  Future<void> dispose() => changes.close();
}

void main() {
  final surface = find.byKey(const ValueKey('video_hardware_underlay'));

  void expectPhysicalViewport(WidgetTester tester, Viewport? actual) {
    final rect = tester.getRect(surface);
    final dpr = tester.view.devicePixelRatio;
    expect(
      actual?.rect,
      Rect.fromLTRB(
        (rect.left * dpr).roundToDouble(),
        (rect.top * dpr).roundToDouble(),
        (rect.right * dpr).roundToDouble(),
        (rect.bottom * dpr).roundToDouble(),
      ),
    );
  }

  testWidgets('Android 主舞台、悬浮小窗、纯音频与退出视口', (tester) async {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(1560, 780);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final harness = await VideoTestHarness.create(
      platform: KonataPlatform.androidPhone,
    );
    addTearDown(harness.dispose);
    final seeded = await harness.seedSampleAnime();
    final port = _AndroidSurfaceSpy();
    addTearDown(port.dispose);
    final controller = harness.createController(
      androidSurfacePort: port,
      enablePeriodicTimers: false,
    );
    addTearDown(controller.dispose);
    final request = VideoLaunchRequest(workId: seeded.work.id);
    await controller.initialize(request);
    await tester.pumpWidget(
      wrapVideoTestApp(
        child: EmbeddedVideoPage(request: request, controller: controller),
      ),
    );
    await tester.pump();
    expect(surface, findsOneWidget);
    expectPhysicalViewport(tester, port.events.last);
    final before = port.events.length;
    await tester.pump();
    expect(port.events, hasLength(before));
    await controller.enterMiniPlayer(desktopAlwaysOnTop: false);
    await tester.pump();
    expect(surface, findsOneWidget);
    expectPhysicalViewport(tester, port.events.last);
    expect(
      port.events.last?.radius,
      KonataPlaybackTokens.floatingMiniRadius * 2,
    );
    final miniRect = port.events.last!.rect;
    controller.miniPlayerOffsetNotifier.value += const Offset(30, 20);
    await tester.pump();
    expectPhysicalViewport(tester, port.events.last);
    expect(port.events.last!.rect, isNot(miniRect));
    await controller.exitMiniPlayerToStage();
    await tester.pump();
    expectPhysicalViewport(tester, port.events.last);
    controller.toggleAudioOnlyMode();
    await tester.pump();
    expect(surface, findsNothing);
    expect(port.events.last, isNull);
    controller.toggleAudioOnlyMode();
    await tester.pump();
    expectPhysicalViewport(tester, port.events.last);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(port.events.last, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Windows 底层渲染与桌面小窗复用原生会话并同步物理视口', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 720);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final harness = await VideoTestHarness.create();
    addTearDown(harness.dispose);
    final seeded = await harness.seedSampleAnime();
    final bridge = _DesktopSurfaceSpy();
    addTearDown(bridge.dispose);
    final clients = <FakeLibMpvClient>[];
    final controller = harness.createController(
      desktopSurfaceBridge: bridge,
      enablePeriodicTimers: false,
      libMpvClientFactory: () {
        final c = FakeLibMpvClient();
        clients.add(c);
        return c;
      },
    );
    addTearDown(controller.dispose);
    final request = VideoLaunchRequest(workId: seeded.work.id);
    await controller.initialize(request);
    await tester.pumpWidget(
      wrapVideoTestApp(
        child: EmbeddedVideoPage(
          request: request,
          controller: controller,
          videoSurfaceBuilder: (_, _) =>
              const SizedBox.expand(key: ValueKey('fallback_texture')),
        ),
      ),
    );
    await tester.pump();
    for (final client in clients.skip(1)) {
      client.emitEvent(const MpvFileLoadedEvent());
    }
    await tester.pump();
    expect(controller.state.windowsUnderlayActive, isTrue);
    expect(surface, findsOneWidget);
    expect(find.byKey(const ValueKey('fallback_texture')), findsNothing);
    expectPhysicalViewport(tester, bridge.events.last);
    final loads = clients.first.commands
        .where((c) => c.first == 'loadfile')
        .length;
    await controller.enterMiniPlayer();
    tester.view.physicalSize = const Size(360, 203);
    await tester.pump();
    expectPhysicalViewport(tester, bridge.events.last);
    expect(bridge.events.last?.radius, 0);
    await controller.exitMiniPlayerToStage();
    tester.view.physicalSize = const Size(1280, 720);
    await tester.pump();
    expectPhysicalViewport(tester, bridge.events.last);
    expect(bridge.created, 1);
    expect(
      clients.first.commands.where((c) => c.first == 'loadfile').length,
      loads,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(bridge.events.last, isNull);
    expect(tester.takeException(), isNull);
  });

  test('旧视口卸载不能隐藏新视口', () async {
    final harness = await VideoTestHarness.create(
      platform: KonataPlatform.androidPhone,
    );
    addTearDown(harness.dispose);
    final port = _AndroidSurfaceSpy();
    addTearDown(port.dispose);
    final controller = harness.createController(
      androidSurfacePort: port,
      enablePeriodicTimers: false,
    );
    addTearDown(controller.dispose);
    final old = Object();
    final next = Object();
    Future<void> sync(Object owner, bool visible) =>
        controller.updateHardwareViewport(
          owner: owner,
          leftPx: 0,
          topPx: 0,
          rightPx: 300,
          bottomPx: 200,
          cornerRadiusPx: 0,
          visible: visible,
        );
    await sync(old, true);
    await sync(next, true);
    await sync(old, false);
    expect(port.events, hasLength(2));
    await sync(next, false);
    expect(port.events.last, isNull);
  });
}
