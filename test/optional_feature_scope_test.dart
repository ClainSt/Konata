import 'dart:async';

import 'package:ccplayer/core/optional_features.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late OptionalFeatures manager;
  setUp(() async {
    SharedPreferences.setMockInitialValues({
      OptionalFeatures.preferenceKey: '{}',
    });
    manager = OptionalFeatures();
    await manager.initialize();
  });
  tearDown(() => manager.dispose());

  test('disabled features cannot acquire a resource lifetime', () {
    expect(
      () => manager.openScope(OptionalFeature.characters),
      throwsStateError,
    );
  });

  test(
    'disable closes every page of that feature and preserves other features',
    () async {
      await manager.setEnabled(OptionalFeature.characters, true);
      await manager.setEnabled(OptionalFeature.credits, true);
      final first = manager.openScope(OptionalFeature.characters);
      final second = manager.openScope(OptionalFeature.characters);
      final other = manager.openScope(OptionalFeature.credits);
      var released = 0;
      for (final scope in [first, second, other]) {
        scope.acquire(Object.new, (_) => released++);
      }
      await manager.setEnabled(OptionalFeature.characters, false);
      await Future.wait([first.cancelled, second.cancelled]);
      expect(released, 2);
      expect(first.disposed && second.disposed, true);
      expect(other.disposed, false);
      expect(other.count<Object>(), 1);
    },
  );

  test(
    'early release and repeated shutdown dispose each resource only once',
    () async {
      await manager.setEnabled(OptionalFeature.characters, true);
      final scope = manager.openScope(OptionalFeature.characters);
      var released = 0;
      final resource = scope.acquire(Object.new, (_) => released++);
      scope.release(resource);
      scope.release(resource);
      scope.dispose();
      scope.dispose();
      await manager.setEnabled(OptionalFeature.characters, false);
      expect(released, 1);
      var created = false;
      expect(
        () => scope.acquire(() {
          created = true;
          return Object();
        }, (_) {}),
        throwsStateError,
      );
      expect(created, false);
    },
  );

  test(
    'switching presentation preserves scope; re-enable creates a fresh scope',
    () async {
      await manager.setCharacterPresentation(1);
      final first = manager.openScope(OptionalFeature.characters);
      await manager.setCharacterPresentation(2);
      expect(first.disposed, false);
      await manager.setCharacterPresentation(0);
      await manager.setCharacterPresentation(1);
      final next = manager.openScope(OptionalFeature.characters);
      expect(first.disposed, true);
      expect(next.disposed, false);
    },
  );

  test('shutdown cancels timers before they can run', () async {
    await manager.setEnabled(OptionalFeature.credits, true);
    final scope = manager.openScope(OptionalFeature.credits);
    var fired = false;
    scope.timer(Duration.zero, () => fired = true);
    scope.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(fired, false);
    expect(scope.count<Timer>(), 0);
  });

  test(
    'one failing resource cleanup does not strand the remaining resources',
    () async {
      await manager.setEnabled(OptionalFeature.credits, true);
      final scope = manager.openScope(OptionalFeature.credits);
      final original = FlutterError.onError;
      final errors = <FlutterErrorDetails>[];
      FlutterError.onError = errors.add;
      var released = false;
      try {
        scope.acquire(Object.new, (_) => throw StateError('cleanup failure'));
        scope.acquire(Object.new, (_) => released = true);
        scope.dispose();
        expect(released, true);
        expect(errors, hasLength(1));
        expect(scope.count<Object>(), 0);
      } finally {
        FlutterError.onError = original;
      }
    },
  );

  test('manager shutdown closes active scopes', () async {
    final local = OptionalFeatures();
    await local.initialize();
    await local.setEnabled(OptionalFeature.characters, true);
    final scope = local.openScope(OptionalFeature.characters);
    local.dispose();
    expect(scope.disposed, true);
    expect(() => local.openScope(OptionalFeature.characters), throwsStateError);
  });
}
