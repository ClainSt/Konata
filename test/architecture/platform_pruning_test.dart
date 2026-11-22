import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 从 Dart 源码中剥离注释与字符串干扰，解析全部顶层 `import` / `export` / `part` 指令的 URI。
///
/// 支持跨行指令、行内/块级注释以及全部 `if (cond) 'uri'` 条件导入分支，
/// 杜绝单行正则漏检隐藏桌面依赖的假绿风险。
List<String> extractDartDirectiveUris(String source) {
  final tokens = _tokenizeTopLevelDirectives(source);
  final uris = <String>[];
  var index = 0;

  while (index < tokens.length) {
    final tok = tokens[index];
    // 跳过文件级注解（如 `@Deprecated('...')`）
    if (tok == '@') {
      index += 1;
      if (index < tokens.length) index += 1;
      while (index + 1 < tokens.length && tokens[index] == '.') {
        index += 2;
      }
      if (index < tokens.length && tokens[index] == '(') {
        var depth = 0;
        while (index < tokens.length) {
          if (tokens[index] == '(') {
            depth += 1;
          } else if (tokens[index] == ')') {
            depth -= 1;
            if (depth == 0) {
              index += 1;
              break;
            }
          }
          index += 1;
        }
      }
      continue;
    }

    if (tok == 'library') {
      while (index < tokens.length && tokens[index] != ';') {
        index += 1;
      }
      index += 1;
      continue;
    }

    if (tok == 'import' || tok == 'export') {
      index += 1;
      if (index < tokens.length && _isStringToken(tokens[index])) {
        uris.add(_unquoteStringToken(tokens[index]));
        index += 1;
      }
      // 完整扫描至 `;`，捕获所有 `if (...) 'uri'` 条件导入/导出目标
      while (index < tokens.length && tokens[index] != ';') {
        if (tokens[index] == 'if') {
          index += 1;
          if (index < tokens.length && tokens[index] == '(') {
            var depth = 0;
            while (index < tokens.length) {
              if (tokens[index] == '(') {
                depth += 1;
              } else if (tokens[index] == ')') {
                depth -= 1;
                if (depth == 0) {
                  index += 1;
                  break;
                }
              }
              index += 1;
            }
          }
          if (index < tokens.length && _isStringToken(tokens[index])) {
            uris.add(_unquoteStringToken(tokens[index]));
            index += 1;
            continue;
          }
        }
        index += 1;
      }
      index += 1;
      continue;
    }

    if (tok == 'part') {
      // 跳过 `part of ...;`，仅收集正向 `part 'uri';`
      if (index + 1 < tokens.length && tokens[index + 1] == 'of') {
        while (index < tokens.length && tokens[index] != ';') {
          index += 1;
        }
        index += 1;
        continue;
      }
      index += 1;
      if (index < tokens.length && _isStringToken(tokens[index])) {
        uris.add(_unquoteStringToken(tokens[index]));
      }
      while (index < tokens.length && tokens[index] != ';') {
        index += 1;
      }
      index += 1;
      continue;
    }

    // Dart 语法规定全部 directive 位于首个声明之前，遇到正文声明即安全终止。
    break;
  }

  return uris;
}

bool _isStringToken(String token) {
  return token.startsWith("'") ||
      token.startsWith('"') ||
      token.startsWith("r'") ||
      token.startsWith('r"');
}

String _unquoteStringToken(String token) {
  var s = token;
  if (s.startsWith('r')) {
    s = s.substring(1);
  }
  if ((s.startsWith("'''") && s.endsWith("'''")) ||
      (s.startsWith('"""') && s.endsWith('"""'))) {
    return s.substring(3, s.length - 3).trim();
  }
  if (s.length >= 2) {
    return s.substring(1, s.length - 1).trim();
  }
  return s.trim();
}

List<String> _tokenizeTopLevelDirectives(String source) {
  final tokens = <String>[];
  final len = source.length;
  var i = 0;

  while (i < len) {
    final cu = source.codeUnitAt(i);
    // 跳过空白
    if (cu <= 32) {
      i += 1;
      continue;
    }
    // 跳过单行注释
    if (cu == 47 && i + 1 < len && source.codeUnitAt(i + 1) == 47) {
      i += 2;
      while (i < len && source.codeUnitAt(i) != 10) {
        i += 1;
      }
      continue;
    }
    // 跳过嵌套块级注释 `/* ... */`
    if (cu == 47 && i + 1 < len && source.codeUnitAt(i + 1) == 42) {
      var depth = 1;
      i += 2;
      while (i + 1 < len && depth > 0) {
        if (source.codeUnitAt(i) == 47 && source.codeUnitAt(i + 1) == 42) {
          depth += 1;
          i += 2;
        } else if (source.codeUnitAt(i) == 42 &&
            source.codeUnitAt(i + 1) == 47) {
          depth -= 1;
          i += 2;
        } else {
          i += 1;
        }
      }
      continue;
    }
    // 字符串字面量（含原始字符串与三引号）
    final isRawString =
        cu == 114 &&
        i + 1 < len &&
        (source.codeUnitAt(i + 1) == 39 || source.codeUnitAt(i + 1) == 34);
    if (cu == 39 || cu == 34 || isRawString) {
      final start = i;
      if (isRawString) i += 1;
      final quote = source.codeUnitAt(i);
      final isTriple =
          i + 2 < len &&
          source.codeUnitAt(i + 1) == quote &&
          source.codeUnitAt(i + 2) == quote;
      i += isTriple ? 3 : 1;
      while (i < len) {
        final cur = source.codeUnitAt(i);
        if (!isRawString && cur == 92) {
          i += 2;
          continue;
        }
        if (isTriple) {
          if (i + 2 < len &&
              cur == quote &&
              source.codeUnitAt(i + 1) == quote &&
              source.codeUnitAt(i + 2) == quote) {
            i += 3;
            break;
          }
          i += 1;
        } else {
          if (cur == quote) {
            i += 1;
            break;
          }
          i += 1;
        }
      }
      tokens.add(source.substring(start, i));
      continue;
    }
    // 标识符 / 关键字
    if (_isIdentStart(cu)) {
      final start = i;
      i += 1;
      while (i < len && _isIdentPart(source.codeUnitAt(i))) {
        i += 1;
      }
      tokens.add(source.substring(start, i));
      continue;
    }
    // 单字符标点（`@`、`.`、`(`、`)`、`;` 等）
    tokens.add(source[i]);
    i += 1;
  }

  return tokens;
}

bool _isIdentStart(int cu) {
  return (cu >= 65 && cu <= 90) ||
      (cu >= 97 && cu <= 122) ||
      cu == 95 ||
      cu == 36;
}

bool _isIdentPart(int cu) {
  return _isIdentStart(cu) || (cu >= 48 && cu <= 57);
}

/// 从给定入口文件递归遍历全部静态 `import`/`export`/`part`（含跨行与条件导入）图。
({Set<String> localFiles, Set<String> externalPackages})
_collectStaticImportGraph(String repoRoot, String entryRelativePath) {
  final visitedFiles = <String>{};
  final externalPackages = <String>{};
  final queue = <String>[entryRelativePath.replaceAll('\\', '/')];

  while (queue.isNotEmpty) {
    final currentRel = queue.removeLast();
    if (!visitedFiles.add(currentRel)) continue;
    final currentFile = File(p.join(repoRoot, currentRel));
    if (!currentFile.existsSync()) continue;
    final content = currentFile.readAsStringSync();
    final currentDir = p.posix.dirname(currentRel);

    for (final uri in extractDartDirectiveUris(content)) {
      if (uri.isEmpty || uri.startsWith('dart:')) continue;
      if (uri.startsWith('package:')) {
        final rest = uri.substring('package:'.length);
        final slash = rest.indexOf('/');
        if (slash <= 0) continue;
        final pkgName = rest.substring(0, slash);
        if (pkgName == 'konata') {
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

const List<String> _forbiddenDesktopPackagesOnAndroid = <String>[
  'flutter_acrylic',
  'window_manager',
  'path_provider_windows',
  'flutter_secure_storage_windows',
  'media_kit_libs_windows_video',
];

const List<String> _forbiddenDesktopFilesOnAndroid = <String>[
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

void main() {
  group('双入口平台物理裁剪与构建契约审计', () {
    final repoRoot = Directory.current.path;

    test('指令解析器完整支持跨行 import/export 与条件导入 if (...) 分支', () {
      const syntheticSource = '''
// 注释测试：import 'package:fake_commented_pkg/ignored.dart';
/*
  块注释测试：import 'package:nested_block_comment/ignored.dart';
  /* 内层嵌套块注释 */
*/
library sample_lib;

@Deprecated('kept for test')
import
    'package:konata/domain/base.dart'
    if (dart.library.io)
      'package:flutter_acrylic/flutter_acrylic.dart'
    if (dart.library.ffi)
      "package:window_manager/window_manager.dart"
    as desk;

export
    'sub/helper.dart'
    if (dart.library.io) 'sub/desktop_only.dart'
    show Foo;

part
    'sub/part_file.dart';

void main() {
  const notAnImport = "import 'package:not_a_real_pkg/x.dart';";
}
''';
      final uris = extractDartDirectiveUris(syntheticSource);
      expect(
        uris,
        containsAll(<String>[
          'package:konata/domain/base.dart',
          'package:flutter_acrylic/flutter_acrylic.dart',
          'package:window_manager/window_manager.dart',
          'sub/helper.dart',
          'sub/desktop_only.dart',
          'sub/part_file.dart',
        ]),
      );
      expect(uris, isNot(contains('package:fake_commented_pkg/ignored.dart')));
      expect(uris, isNot(contains('package:nested_block_comment/ignored.dart')));
      expect(uris, isNot(contains('package:not_a_real_pkg/x.dart')));
    });

    test('lib/main_android.dart 静态导入图零桌面包与零桌面模块残留', () {
      final graph = _collectStaticImportGraph(repoRoot, 'lib/main_android.dart');

      // 确认真正遍历到完整 Android 应用树，避免空图假绿
      expect(
        graph.localFiles,
        contains('lib/composition/android_composition_root.dart'),
      );
      expect(graph.localFiles, contains('lib/presentation/app/konata_app.dart'));
      expect(
        graph.localFiles,
        contains('lib/presentation/shell/desktop_shell.dart'),
      );

      for (final pkg in _forbiddenDesktopPackagesOnAndroid) {
        expect(
          graph.externalPackages.contains(pkg),
          isFalse,
          reason: 'Android 入口不得静态依赖桌面包：$pkg',
        );
      }

      for (final file in _forbiddenDesktopFilesOnAndroid) {
        expect(
          graph.localFiles.contains(file),
          isFalse,
          reason: 'Android 入口静态导入图出现桌面模块残留：$file',
        );
      }
    });

    test('integration_test/runtime_workload_android_test.dart 零桌面组装根残留', () {
      final graph = _collectStaticImportGraph(
        repoRoot,
        'integration_test/runtime_workload_android_test.dart',
      );

      expect(
        graph.localFiles,
        contains('lib/composition/android_composition_root.dart'),
      );
      expect(graph.localFiles, contains('integration_test/runtime_workload_body.dart'));
      expect(
        graph.localFiles,
        isNot(contains('lib/main.dart')),
        reason: 'Android 基准测试严禁导入桌面入口 lib/main.dart',
      );
      for (final pkg in _forbiddenDesktopPackagesOnAndroid) {
        expect(
          graph.externalPackages.contains(pkg),
          isFalse,
          reason: 'Android 基准测试入口不得引入桌面包：$pkg',
        );
      }
      for (final file in _forbiddenDesktopFilesOnAndroid) {
        expect(
          graph.localFiles.contains(file),
          isFalse,
          reason: 'Android 基准测试静态图出现桌面模块残留：$file',
        );
      }
    });

    test('lib/main.dart 完整保留 Windows 组装根且不含 Android 分支', () {
      final graph = _collectStaticImportGraph(repoRoot, 'lib/main.dart');
      expect(
        graph.localFiles,
        contains('lib/composition/windows_composition_root.dart'),
      );
      expect(
        graph.localFiles,
        contains('lib/infrastructure/players/d3d11_video_bridge.dart'),
      );
      expect(
        graph.localFiles,
        contains('lib/presentation/shell/top_nav_bar.dart'),
      );
      expect(
        graph.localFiles,
        contains('lib/presentation/settings/settings_external_tools_panel.dart'),
      );

      final winRootText = File(
        p.join(repoRoot, 'lib', 'composition', 'windows_composition_root.dart'),
      ).readAsStringSync();
      expect(
        winRootText,
        isNot(contains('Platform.isAndroid')),
        reason: 'Windows 组装根严禁残留 Android 运行时分支',
      );
    });

    test('Android 构建与正式签名脚本准确映射默认入口及基准测试入口', () {
      final gradleText = File(
        p.join(repoRoot, 'android', 'app', 'build.gradle.kts'),
      ).readAsStringSync();
      expect(gradleText, contains('KONATA_RELEASE_VALIDATION'));
      expect(gradleText, contains('lib/main_android.dart'));
      expect(gradleText, contains('normalized == "lib/main.dart"'));
      expect(
        gradleText,
        contains('normalized == "integration_test/runtime_workload_test.dart"'),
      );
      expect(
        gradleText,
        contains('integration_test/runtime_workload_android_test.dart'),
      );

      final signScript = File(
        p.join(repoRoot, 'tool', 'build_signed_android.ps1'),
      ).readAsStringSync();
      expect(signScript, contains('-t lib/main_android.dart'));
    });
  });
}
