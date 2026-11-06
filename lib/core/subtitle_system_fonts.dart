import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// libass on Android has no system font provider. Expose a bounded set of
/// installed fallback fonts through links instead of bundling or copying them.
Future<void> configureAndroidSubtitleFonts(
  Future<void> Function(String, String) setProperty, {
  Directory? systemFonts,
  Directory? cache,
  bool setDefaultFamily = true,
}) async {
  final system = systemFonts ?? Directory('/system/fonts');
  final root = cache ?? await getTemporaryDirectory();
  final directory = Directory(p.join(root.path, 'subtitle-system-fonts-v1'));
  await directory.create(recursive: true);
  // Some Android system images use MiSans for missing CJK faces. Leave
  // explicitly configured and subtitle-provided families in control.
  final miSans = File(p.join(system.path, 'MiSansVF.ttf'));
  final useMiSans = setDefaultFamily && await miSans.exists();
  final candidates = [
    ['NotoSansCJK-Regular.ttc', 'NotoSansCJK-VF.ttc', 'NotoSansSC-Regular.otf'],
    ['Roboto-Regular.ttf', 'RobotoStatic-Regular.ttf', 'Roboto-VF.ttf'],
    if (useMiSans) ['MiSansVF.ttf'],
  ];
  for (var i = 0; i < candidates.length; i++) {
    for (final name in candidates[i]) {
      final file = File(p.join(system.path, name));
      if (!await file.exists()) continue;
      final link = Link(
        p.join(directory.path, 'fallback-$i${p.extension(name)}'),
      );
      if (await FileSystemEntity.type(link.path, followLinks: false) ==
          FileSystemEntityType.link) {
        if (await link.target() != file.path) await link.update(file.path);
      } else {
        await link.create(file.path);
      }
      break;
    }
  }
  await setProperty('sub-fonts-dir', directory.path);
  if (setDefaultFamily) {
    await setProperty('sub-font', useMiSans ? 'MiSans VF' : 'Noto Sans CJK SC');
  }
}
