import 'dart:io';

import 'package:ccplayer/core/mpv_engine_store.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late MpvEngineStore engine;
  late List<int> expectedBytes;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('ccplayer-mpv-engine-');
    expectedBytes = List<int>.generate(3000, (index) => index % 251);
    engine = MpvEngineStore(
      rootOverride: root,
      dllHash: sha256.convert(expectedBytes).toString(),
    );
  });
  tearDown(() => root.delete(recursive: true));

  test('default engine remains selected until valid DLL and explicit opt-in', () async {
    await engine.initialize();
    expect(engine.enabled, isFalse);
    expect(await engine.isInstalledAndValid(), isFalse);
    expect(await engine.preferredStartupLibrary(), isNull);
    await expectLater(engine.setEnabled(true), throwsStateError);

    final library = await engine.libraryFile;
    await library.writeAsBytes(expectedBytes);
    expect(await engine.isInstalledAndValid(), isTrue);
    expect(await engine.preferredStartupLibrary(), isNull);
    await engine.setEnabled(true);
    expect(await engine.preferredStartupLibrary(), library.path);
    expect(engine.activeThisSession, isFalse);
    engine.recordStartupResult(enhanced: true);
    expect(engine.activeThisSession, isTrue);
    await engine.setEnabled(false);
    expect(await engine.preferredStartupLibrary(), isNull);
  });

  test('file corruption disables optional startup without deleting old DLL', () async {
    await engine.initialize();
    final library = await engine.libraryFile;
    await library.writeAsBytes(expectedBytes);
    await engine.setEnabled(true);
    await library.writeAsBytes(List<int>.filled(expectedBytes.length, 7));
    expect(await engine.isInstalledAndValid(), isFalse);
    expect(await engine.preferredStartupLibrary(), isNull);
    expect(await library.exists(), isTrue);
  });

  test('unrecognized 7z archive cannot install or alter existing DLL', () async {
    final archive = File(p.join(root.path, 'untrusted.7z'));
    await archive.writeAsBytes(List<int>.filled(2048, 55));
    final library = await engine.libraryFile;
    await library.writeAsBytes(expectedBytes);
    await expectLater(
      engine.installFromArchive(archive),
      throwsA(isA<FormatException>()),
    );
    expect(await library.readAsBytes(), expectedBytes);
  });
}
