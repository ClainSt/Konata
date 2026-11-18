import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 从给定入口文件递归遍历全部静态 `import`/`export`/`part` 图，返回触达的相对路径与外部包名集合。
({Set<String> localFiles, Set<String> externalPackages})
_collectStaticImportGraph(String repoRoot, String entryRelativePath) {
  final visitedFiles = <String>{};
  final externalPackages = <String>{};
  final queue = <String>[entryRelativePath.replaceAll('\\', '/')];

  final directiveRegex = RegExp(
    r'''^\s*(?:import|export|part)\s+['"]([^'"]+)['"]''',
    multiLine: true,
  );

  while (queue.isNotEmpty) {
    final currentRel = queue.removeLast();
    if (!visitedFiles.add(currentRel)) continue;
    final currentFile = File(p.join(repoRoot, currentRel));
    if (!currentFile.existsSync()) continue;
    final content = currentFile.readAsStringSync();
    final currentDir = p.posix.dirname(currentRel);

    for (final match in directiveRegex.allMatches(content)) {
      final uri = match.group(1)!.trim();
      if (uri.startsWith('dart:')) continue;
      if (uri.startsWith('package:')) {
        final rest = uri.substring('package:'.length);
        final slash = rest.indexOf('/');
        if (slash <= 0) continue;
        final pkgName = rest.substring(0, slash);
        if (pkgName == 'ccplayer') {
          final targetRel = 'lib/${rest.substring(slash + 1)}';
          if (!visitedFiles.contains(targetRel)) {
            queue.add(targetRel);
          }
        } else {
          externalPackages.add(pkgName);
        }
        continue;
      }
      final resolved = p.posix.normalize(p.posix.join(currentDir, uri));
      if (!visitedFiles.contains(resolved)) {
        queue.add(resolved);
      }
    }
  }

  return (localFiles: visitedFiles, externalPackages: externalPackages);
}

void main() {
  group('双入口平台物理裁剪与构建契约审计', () {
    final repoRoot = Directory.current.path;

    test('lib/main_android.dart 静态导入图零桌面包与零桌面模块残留', () {
      final graph = _collectStaticImportGraph(repoRoot, 'lib/main_android.dart');

      // 确认真正遍历到完整 Android 应用树，避免空图假绿
      expect(graph.localFiles, contains('lib/composition/android_composition_root.dart'));
      expect(graph.localFiles, contains('lib/presentation/app/konata_app.dart'));
      expect(graph.localFiles, contains('lib/presentation/shell/desktop_shell.dart'));

      // 严禁触达任何桌面专属插件包
      const forbiddenPackages = <String>[
        'flutter_acrylic',
        'window_manager',
      ];
      for (final pkg in forbiddenPackages) {
        expect(
          graph.externalPackages.contains(pkg),
          isFalse,
          reason: 'Android 入口不得静态依赖桌面包：$pkg',
        );
      }

      // 严禁触达任何桌面独占模块文件
      const forbiddenFiles = <String>[
        'lib/composition/windows_composition_root.dart',
        'lib/infrastructure/players/d3d11_video_bridge.dart',
        'lib/infrastructure/players/real_external_player_launcher.dart',
        'lib/infrastructure/players/win32_ffi_bindings.dart',
        'lib/infrastructure/players/potplayer_win32_tracker.dart',
        'lib/infrastructure/players/mpv_ipc_tracker.dart',
        'lib/infrastructure/players/foobar_beefweb_tracker.dart',
        'lib/infrastructure/players/player_tracking_isolates.dart',
        'lib/infrastructure/players/windows_code_page_decoder.dart',
        'lib/presentation/settings/settings_external_tools_panel.dart',
        'lib/presentation/shell/top_nav_bar.dart',
        'lib/presentation/shell/window_controls.dart',
        'lib/presentation/theme/window_material_controller.dart',
      ];
      for (final file in forbiddenFiles) {
        expect(
          graph.localFiles.contains(file),
          isFalse,
          reason: 'Android 入口静态导入图出现桌面模块残留：$file',
        );
      }
    });

    test('lib/main.dart 完整保留 Windows 组装根兼容锁定门禁', () {
      final graph = _collectStaticImportGraph(repoRoot, 'lib/main.dart');
      expect(graph.localFiles, contains('lib/composition/windows_composition_root.dart'));
      expect(graph.localFiles, contains('lib/infrastructure/players/d3d11_video_bridge.dart'));
      expect(graph.localFiles, contains('lib/presentation/shell/top_nav_bar.dart'));
      expect(graph.localFiles, contains('lib/presentation/settings/settings_external_tools_panel.dart'));
    });

    test('Android 构建与正式签名脚本准确映射默认入口且保护显式测试入口', () {
      final gradleText = File(
        p.join(repoRoot, 'android', 'app', 'build.gradle.kts'),
      ).readAsStringSync();
      expect(gradleText, contains('KONATA_RELEASE_VALIDATION'));
      expect(gradleText, contains('lib/main_android.dart'));
      expect(gradleText, contains('normalized == "lib/main.dart"'));

      final signScript = File(
        p.join(repoRoot, 'tool', 'build_signed_android.ps1'),
      ).readAsStringSync();
      expect(signScript, contains('-t lib/main_android.dart'));
    });
  });
}
