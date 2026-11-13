import 'dart:async';

import 'package:ccplayer/ui/android_native_video.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:smb_connect/src/configuration.dart';
import 'package:smb_connect/src/connect/common/common_server_message_block_request.dart';
import 'package:smb_connect/src/connect/common/common_server_message_block_response.dart';
import 'package:smb_connect/src/connect/smb_transport.dart';
import 'package:smb_connect/src/exceptions.dart';
import 'package:smb_connect/src/smb/request_param.dart';

class _Config extends Fake implements Configuration {
  @override
  bool get debugPrint => false;
}

class _Request extends Fake implements CommonServerMessageBlockRequest {
  @override
  int getMid() => 1;
  @override
  int getCommand() => 0;
}

class _Response extends Fake implements CommonServerMessageBlockResponse {
  int retained = 0;
  @override
  void reset() {}
  @override
  void setCommand(int command) {}
  @override
  void setRetainPayload() => retained++;
}

class _TimeoutTransport extends SmbTransport {
  _TimeoutTransport({
    this.timeoutsBeforeSuccess = 100,
    this.sendFailure,
    this.receiveFailure,
  }) : super(_Config(), 'fixture.invalid');
  final int timeoutsBeforeSuccess;
  final Object? sendFailure, receiveFailure;
  int sends = 0, waits = 0;
  final sentParams = <Set<RequestParam>?>[];
  @override
  Future<void> doSend(
    CommonServerMessageBlockRequest request, [
    Set<RequestParam>? params,
  ]) async {
    sends++;
    sentParams.add(params);
    if (sendFailure case final error?) throw error;
  }

  @override
  Future<CommonServerMessageBlockResponse> waitResponse(
    int key,
    CommonServerMessageBlockResponse response,
  ) async {
    waits++;
    if (receiveFailure case final error?) throw error;
    if (waits <= timeoutsBeforeSuccess) {
      throw TimeoutException('synthetic timeout');
    }
    return response;
  }
}

class _Native extends Fake implements NativePlayer {
  final callbacks = <Future<void> Function()>[];
  final calls = <String>[];
  bool fail = false;
  final failure = StateError('synthetic detach failure');
  @override
  bool get disposed => false;
  @override
  PlayerConfiguration get configuration => const PlayerConfiguration();
  @override
  List<Future<void> Function()> get release => callbacks;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #setProperty) {
      calls.add('${invocation.positionalArguments[0]}');
      return fail ? Future<void>.error(failure) : Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}

class _Player extends Fake implements Player {
  _Player(this.native);
  final _Native native;
  @override
  NativePlayer get platform => native;
  @override
  Future<int> get handle async => 1;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'NO_RETRY sends once on timeout; repeated calls release the mutex',
    () async {
      final transport = _TimeoutTransport();
      for (var i = 1; i <= 2; i++) {
        await expectLater(
          transport
              .sendrecv(
                _Request(),
                response: _Response(),
                params: {RequestParam.NO_RETRY},
              )
              .timeout(const Duration(seconds: 1)),
          throwsA(isA<SmbException>()),
        );
        expect(transport.sends, i);
        expect(transport.waits, i);
      }
    },
  );

  test(
    'default and empty params retain the five-attempt timeout limit',
    () async {
      for (final params in <Set<RequestParam>?>[null, {}]) {
        final transport = _TimeoutTransport();
        await expectLater(
          transport.sendrecv(_Request(), response: _Response(), params: params),
          throwsA(isA<SmbException>()),
        );
        expect(transport.sends, 5);
        expect(transport.waits, 5);
      }
    },
  );

  test('retry-enabled request succeeds after one timeout', () async {
    final transport = _TimeoutTransport(timeoutsBeforeSuccess: 1);
    final response = _Response();
    expect(
      await transport.sendrecv(_Request(), response: response),
      same(response),
    );
    expect(transport.sends, 2);
    expect(transport.waits, 2);
  });

  test(
    'NO_RETRY can combine with RETAIN_PAYLOAD and return first response',
    () async {
      final transport = _TimeoutTransport(timeoutsBeforeSuccess: 0);
      final response = _Response();
      final params = {RequestParam.NO_RETRY, RequestParam.RETAIN_PAYLOAD};
      expect(
        await transport.sendrecv(
          _Request(),
          response: response,
          params: params,
        ),
        same(response),
      );
      expect(transport.sends, 1);
      expect(transport.sentParams.single, params);
      expect(response.retained, 1);
    },
  );

  test('NO_RETRY remains effective when combined flags time out', () async {
    final transport = _TimeoutTransport();
    final response = _Response();
    await expectLater(
      transport.sendrecv(
        _Request(),
        response: response,
        params: {RequestParam.NO_RETRY, RequestParam.RETAIN_PAYLOAD},
      ),
      throwsA(isA<SmbException>()),
    );
    expect(transport.sends, 1);
    expect(response.retained, 1);
  });

  test(
    'send and non-timeout receive failures keep their identity without retry',
    () async {
      final failure = StateError('synthetic I/O failure');
      for (final params in <Set<RequestParam>?>[
        null,
        {RequestParam.NO_RETRY},
      ]) {
        for (final sending in [true, false]) {
          final transport = _TimeoutTransport(
            sendFailure: sending ? failure : null,
            receiveFailure: sending ? null : failure,
          );
          for (var call = 1; call <= 2; call++) {
            await expectLater(
              transport
                  .sendrecv(_Request(), response: _Response(), params: params)
                  .timeout(const Duration(seconds: 1)),
              throwsA(same(failure)),
            );
            expect(transport.sends, call);
            expect(transport.waits, sending ? 0 : call);
          }
        }
      }
    },
  );

  test(
    'queued NO_RETRY callers each send once after the prior timeout',
    () async {
      final transport = _TimeoutTransport();
      await Future.wait([
        for (var i = 0; i < 3; i++)
          expectLater(
            transport
                .sendrecv(
                  _Request(),
                  response: _Response(),
                  params: {RequestParam.NO_RETRY},
                )
                .timeout(const Duration(seconds: 1)),
            throwsA(isA<SmbException>()),
          ),
      ]);
      expect(transport.sends, 3);
      expect(transport.waits, 3);
    },
  );

  test(
    'failed Android close shares its attempt then allows release callback retry',
    () async {
      final native = _Native();
      final output = AndroidNativeVideo(
        _Player(native),
        const VideoControllerConfiguration(),
      );
      await output.initialize();
      native.fail = true;
      final closing = output.close();
      await expectLater(closing, throwsA(same(native.failure)));
      final count = native.calls.length;
      native.fail = false;
      await native.callbacks.single();
      expect(native.calls.length, count + 2);
      await output.close();
      expect(native.calls.length, count + 2);
      expect(() => output.rect.addListener(() {}), throwsFlutterError);
    },
  );
}
