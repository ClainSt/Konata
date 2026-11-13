import 'dart:async';
import 'package:ccplayer/ui/windows_hdr_output.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

class _Native implements NativePlayer {
  _Native(this.events);
  final List<String> events;
  void Function(String key, String value)? onSet;
  Completer<void>? observeGate;
  final observeStarted = Completer<void>();
  bool observing = false;
  final values = <String, String>{
    'target-prim': 'auto',
    'target-trc': 'auto',
    'target-peak': 'auto',
    'video-params/gamma': 'pq',
  };
  @override
  dynamic noSuchMethod(Invocation invocation) {
    final args = invocation.positionalArguments;
    if (invocation.memberName == #disposed) return false;
    if (invocation.memberName == #getProperty) {
      return Future<String>.value(values[args.first]!);
    }
    if (invocation.memberName == #setProperty) {
      values[args[0] as String] = args[1] as String;
      events.add('${args[0]}=${args[1]}');
      onSet?.call(args[0] as String, args[1] as String);
      return Future<void>.value();
    }
    if (invocation.memberName == #observeProperty) {
      if (!observeStarted.isCompleted) observeStarted.complete();
      return (observeGate?.future ?? Future<void>.value()).then((_) {
        observing = true;
      });
    }
    if (invocation.memberName == #unobserveProperty) {
      observing = false;
      return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('ccplayer/native_video');
  late List<String> events;
  late _Native native;
  late List<Object> errors;
  late bool active;
  late bool rejectPq;
  Future<void> Function(int)? onBegin;
  var epoch = 0;
  setUp(() {
    events = [];
    errors = [];
    native = _Native(events);
    active = true;
    rejectPq = false;
    onBegin = null;
    epoch = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'beginColor') {
            await onBegin?.call(epoch + 1);
            events.add('begin');
            return {'epoch': ++epoch, 'hdrActive': active, 'peak': 600};
          }
          final args = call.arguments as List;
          if (args[2] != epoch) throw PlatformException(code: 'output_color');
          final pq = args[1] as bool;
          events.add('commit:$pq');
          if (pq && rejectPq) throw PlatformException(code: 'output_color');
          expect(native.values['target-trc'], pq ? 'pq' : 'auto');
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  test('close waits for pending observation and removes it', () async {
    native.observeGate = Completer<void>();
    final output = WindowsHdrOutput(native, 90, errors.add);
    final initializing = output.initialize();
    await native.observeStarted.future;
    final closing = output.close();
    await Future<void>.delayed(Duration.zero);
    native.observeGate!.complete();
    await initializing;
    await closing;
    expect(native.observing, isFalse);
    expect(events.where((event) => event.startsWith('commit:')), isEmpty);
  });
  test('repeated close shares cleanup and restores preferences once', () async {
    final output = WindowsHdrOutput(native, 91, errors.add);
    await output.initialize();
    events.clear();
    await Future.wait([output.close(), output.close()]);
    expect(events.where((event) => event == 'target-trc=auto'), hasLength(1));
  });
  test('close during fallback does not present after cancellation', () async {
    rejectPq = true;
    final started = Completer<void>();
    final resume = Completer<void>();
    onBegin = (number) async {
      if (number == 2) {
        started.complete();
        await resume.future;
      }
    };
    final output = WindowsHdrOutput(native, 92, errors.add);
    final initializing = output.initialize();
    await started.future;
    final closing = output.close();
    resume.complete();
    await initializing;
    await closing;
    expect(events, isNot(contains('commit:false')));
    expect(native.observing, isFalse);
    expect(native.values['target-trc'], 'auto');
    expect(errors, isEmpty);
  });
  test(
    'PQ pixels are configured only while presentation is gated; SDR restores preferences',
    () async {
      final output = WindowsHdrOutput(native, 1, errors.add);
      await output.initialize();
      expect(events, [
        'begin',
        'target-prim=bt.2020',
        'target-trc=pq',
        'target-peak=600',
        'commit:true',
      ]);
      native.values['video-params/gamma'] = 'bt.1886';
      await output.refresh();
      expect(events.sublist(5), [
        'begin',
        'target-prim=auto',
        'target-trc=auto',
        'target-peak=auto',
        'commit:false',
      ]);
      expect(errors, isEmpty);
      await output.close();
    },
  );
  test('rejected HDR presentation restores SDR before committing', () async {
    rejectPq = true;
    final output = WindowsHdrOutput(native, 2, errors.add);
    await output.initialize();
    expect(events.last, 'commit:false');
    expect(
      events.indexOf('target-trc=auto'),
      greaterThan(events.indexOf('commit:true')),
    );
    expect(native.values['target-peak'], 'auto');
    expect(errors, isEmpty);
    await output.close();
  });
  test(
    'an unavailable HDR display preserves the existing SDR targets',
    () async {
      active = false;
      final output = WindowsHdrOutput(native, 3, errors.add);
      await output.initialize();
      expect(events, isNot(contains('target-trc=pq')));
      expect(events.last, 'commit:false');
      await output.close();
    },
  );
  test(
    'unsupported explicit HDR is reported without silently rewriting the user setting',
    () async {
      active = false;
      native.values['target-trc'] = 'pq';
      final output = WindowsHdrOutput(native, 4, errors.add);
      await output.initialize();
      expect(errors, hasLength(1));
      expect(events, ['begin']);
      expect(native.values['target-trc'], 'pq');
      await output.close();
    },
  );
  test(
    'display changes during a transaction discard stale HDR and apply SDR',
    () async {
      final output = WindowsHdrOutput(native, 5, errors.add);
      native.onSet = (key, value) {
        if (key == 'target-trc' && value == 'pq') {
          active = false;
          epoch++;
          output.refresh();
        }
      };
      await output.initialize();
      expect(errors, isEmpty);
      expect(events.last, 'commit:false');
      expect(native.values['target-trc'], 'auto');
      await output.close();
    },
  );
}
