import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata/bootstrap/android_platform_bridges.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('USB 撤销成功、拒绝、旧响应与平台异常明确区分', () async {
    const channel = MethodChannel('konata/test_audio_route');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final adapter = AndroidAudioRouteAdapter(
      channel: channel,
      isSupported: () => true,
    );
    addTearDown(adapter.dispose);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    Map<String, Object>? response;
    var fail = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'negotiateBitPerfectUsb');
      expect((call.arguments as Map)['enable'], false);
      if (fail) throw PlatformException(code: 'route_failed');
      return response;
    });
    response = {
      'supported': true,
      'engaged': false,
      'operationSucceeded': true,
    };
    expect(
      (await adapter.negotiateBitPerfectUsb(enable: false)).operationSucceeded,
      isTrue,
    );
    response = {
      'supported': true,
      'engaged': false,
      'operationSucceeded': false,
    };
    expect(
      (await adapter.negotiateBitPerfectUsb(enable: false)).operationSucceeded,
      isFalse,
    );
    response = {'supported': true, 'engaged': false};
    expect(
      (await adapter.negotiateBitPerfectUsb(enable: false)).operationSucceeded,
      isFalse,
    );
    fail = true;
    final failed = await adapter.negotiateBitPerfectUsb(enable: false);
    expect(failed.operationSucceeded, isFalse);
    expect(failed.engaged, isFalse);
  });
}
