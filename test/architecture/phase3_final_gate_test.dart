import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:konata/domain/models/media_extensions.dart';

/// 剔除 Dart 单行与块级注释，可选同时清空字符串内容以避免正则误判多行词表文本。
String _stripDartComments(String source, {bool blankStrings = false}) {
  // 统一归一化换行符，避免 Windows CRLF 检出导致跨行源码静态契约误报。
  source = source.replaceAll('\r\n', '\n');
  final out = StringBuffer();
  var i = 0;
  var inSingle = false;
  var inDouble = false;
  var inTripleSingle = false;
  var inTripleDouble = false;
  var rawString = false;

  void writeStrChar(String c) {
    if (!blankStrings || c == '\n') {
      out.write(c);
    }
  }

  while (i < source.length) {
    final ch = source[i];
    final next = i + 1 < source.length ? source[i + 1] : '';
    final next2 = i + 2 < source.length ? source[i + 2] : '';

    if (inTripleSingle) {
      if (ch == "'" && next == "'" && next2 == "'") {
        out.write("'''");
        i += 3;
        inTripleSingle = false;
        rawString = false;
        continue;
      }
      writeStrChar(ch);
      i++;
      continue;
    }
    if (inTripleDouble) {
      if (ch == '"' && next == '"' && next2 == '"') {
        out.write('"""');
        i += 3;
        inTripleDouble = false;
        rawString = false;
        continue;
      }
      writeStrChar(ch);
      i++;
      continue;
    }
    if (inSingle) {
      if (!rawString && ch == r'\' && i + 1 < source.length) {
        writeStrChar(ch);
        writeStrChar(next);
        i += 2;
        continue;
      }
      if (ch == "'") {
        out.write("'");
        inSingle = false;
        rawString = false;
      } else {
        writeStrChar(ch);
      }
      i++;
      continue;
    }
    if (inDouble) {
      if (!rawString && ch == r'\' && i + 1 < source.length) {
        writeStrChar(ch);
        writeStrChar(next);
        i += 2;
        continue;
      }
      if (ch == '"') {
        out.write('"');
        inDouble = false;
        rawString = false;
      } else {
        writeStrChar(ch);
      }
      i++;
      continue;
    }

    if (ch == '/' && next == '/') {
      while (i < source.length && source[i] != '\n') {
        i++;
      }
      continue;
    }
    if (ch == '/' && next == '*') {
      i += 2;
      while (i + 1 < source.length && !(source[i] == '*' && source[i + 1] == '/')) {
        if (source[i] == '\n') out.write('\n');
        i++;
      }
      i += 2;
      continue;
    }

    if (ch == 'r' && (next == "'" || next == '"')) {
      rawString = true;
      out.write(ch);
      i++;
      continue;
    }
    if (ch == "'" && next == "'" && next2 == "'") {
      inTripleSingle = true;
      out.write("'''");
      i += 3;
      continue;
    }
    if (ch == '"' && next == '"' && next2 == '"') {
      inTripleDouble = true;
      out.write('"""');
      i += 3;
      continue;
    }
    if (ch == "'") {
      inSingle = true;
      out.write(ch);
      i++;
      continue;
    }
    if (ch == '"') {
      inDouble = true;
      out.write(ch);
      i++;
      continue;
    }

    out.write(ch);
    i++;
  }
  return out.toString();
}

int _lineOfOffset(String text, int offset) =>
    '\n'.allMatches(text.substring(0, offset)).length + 1;

List<File> _listDartFiles(Directory root) {
  final files = <File>[];
  for (final entity in root.listSync(recursive: true, followLinks: false)) {
    if (entity is File && entity.path.endsWith('.dart')) {
      files.add(entity);
    }
  }
  files.sort((a, b) => a.path.compareTo(b.path));
  return files;
}

String _relPath(String repoRoot, String filePath) =>
    p.relative(filePath, from: repoRoot).replaceAll('\\', '/');

void main() {
  final repoRoot = Directory.current.path;
  final libDir = Directory(p.join(repoRoot, 'lib'));
  final allLibFiles = _listDartFiles(libDir);

  group('Gate A · Phase 3 终审静态契约零妥协门禁', () {
    test('1. [#1] 全仓仅允许 UnifiedPlaybackEngine 唯一 1 处调用 FfiLibMpvClient.create(', () {
      final callHits = <String>[];
      final callRegex = RegExp(r'\bFfiLibMpvClient\.create\b');
      final factoryDeclRegex = RegExp(r'\bfactory\s+FfiLibMpvClient\.create\s*\(');

      for (final file in allLibFiles) {
        final rel = _relPath(repoRoot, file.path);
        final stripped = _stripDartComments(file.readAsStringSync());
        final lines = stripped.split('\n');
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          if (!callRegex.hasMatch(line)) continue;
          if (rel == 'lib/infrastructure/players/libmpv_ffi.dart' &&
              factoryDeclRegex.hasMatch(line)) {
            continue;
          }
          callHits.add('$rel:${i + 1}: ${line.trim()}');
        }
      }

      expect(
        callHits.length,
        equals(1),
        reason: '全仓只允许 UnifiedPlaybackEngine 内部唯一 1 处持有 FfiLibMpvClient.create，实测命中：\n${callHits.join('\n')}',
      );
      expect(
        callHits.single.startsWith('lib/application/playback/unified_playback_engine.dart:'),
        isTrue,
        reason: '唯一调用点必须位于 UnifiedPlaybackEngine，实测：${callHits.single}',
      );
    });

    test('2. [#24] 手机导航胶囊恢复实时毛玻璃，桌面顶栏恢复连续平滑字重与阴影过渡', () {
      final capsuleSrc = _stripDartComments(
        File(p.join(repoRoot, 'lib/presentation/shell/capsule_navigation.dart'))
            .readAsStringSync(),
      );
      expect(
        capsuleSrc,
        contains('enableBackdropBlur: !vertical'),
        reason: '手机端 (!vertical) 必须开启实时毛玻璃',
      );
      expect(
        capsuleSrc,
        isNot(contains('enableBackdropBlur: false')),
        reason: '严禁硬编码关闭导航胶囊毛玻璃',
      );

      final topNavSrc = _stripDartComments(
        File(p.join(repoRoot, 'lib/presentation/shell/top_nav_bar.dart'))
            .readAsStringSync(),
      );
      expect(topNavSrc, isNot(contains('t >= 0.5')), reason: '严禁字重阶跃硬切');
      expect(topNavSrc, isNot(contains('t >= 0.85')), reason: '严禁阴影阶跃硬切');
      expect(
        topNavSrc,
        contains('lerpDouble('),
        reason: '桌面顶栏必须保留连续可变字重插值',
      );
      expect(
        topNavSrc,
        contains('blurRadius: 6.0 * t'),
        reason: '桌面顶栏必须保留克制柔和的连续发光阴影半径过渡',
      );
    });

    test('3. [#3] Android MainActivity 禁止 FlutterSurfaceView.setZOrderOnTop(true) 越过 DecorView', () {
      final mainActivitySrc = File(
        p.join(repoRoot, 'android/app/src/main/kotlin/com/anime/konata/MainActivity.kt'),
      ).readAsStringSync();

      final usesSurface = mainActivitySrc.contains('RenderMode.surface');
      final usesTexture = mainActivitySrc.contains('RenderMode.texture');
      expect(usesSurface || usesTexture, isTrue);

      if (usesSurface) {
        expect(
          mainActivitySrc,
          contains('override fun onFlutterSurfaceViewCreated'),
          reason: '使用 RenderMode.surface 时必须覆写 onFlutterSurfaceViewCreated',
        );
        expect(mainActivitySrc, contains('setZOrderOnTop(false)'));
        expect(mainActivitySrc, contains('setZOrderMediaOverlay(true)'));
        expect(mainActivitySrc, contains('PixelFormat.TRANSLUCENT'));
      }
    });

    test('4. [#5] Windows 底层子窗口与 Android Underlay 悬浮小窗统一免除挖空阻断', () {
      final miniSrc = _stripDartComments(
        File(
          p.join(
            repoRoot,
            'lib/presentation/widgets/playback/konata_floating_mini_player.dart',
          ),
        ).readAsStringSync(),
      );
      expect(miniSrc, contains('usesCanvasHolePunchUnderlay'));
      expect(miniSrc, contains('windowsUnderlayActive'));
      expect(miniSrc, isNot(contains('isAndroidVideoUnderlay')));
      expect(
        miniSrc,
        contains('usesCanvasHolePunchUnderlay\n                ? bodyChild'),
      );
      expect(
        miniSrc,
        contains('usesCanvasHolePunchUnderlay\n        ? innerCard'),
      );

      final barSrc = _stripDartComments(
        File(p.join(repoRoot, 'lib/presentation/audio/mini_audio_bar.dart'))
            .readAsStringSync(),
      );
      expect(barSrc, contains('usesVideoCanvasHolePunch'));
      expect(barSrc, contains('allowClipRadius: !usesVideoCanvasHolePunch'));
      expect(barSrc, isNot(contains('allowClipRadius: !KonataAdaptiveTokens.isAndroid')));
    });

    test('5. [#7] Windows 底栏与视频侧栏双模截图入口完整，Android 竖屏旋转等待设有界超时', () {
      final overlaysSrc = _stripDartComments(
        File(p.join(repoRoot, 'lib/presentation/video/embedded_video_overlays.dart'))
            .readAsStringSync(),
      );
      expect(overlaysSrc, contains("ValueKey('video_desktop_screenshot_button')"));
      expect(overlaysSrc, contains('onShowScreenshotMenu(btnCtx)'));
      expect(overlaysSrc, contains('纯净原画帧 (S)'));
      expect(overlaysSrc, contains('带字幕合成帧 (Shift+S)'));

      final sheetSrc = _stripDartComments(
        File(p.join(repoRoot, 'lib/presentation/video/video_side_sheet.dart'))
            .readAsStringSync(),
      );
      expect(sheetSrc, contains("ValueKey('video_sheet_screenshot_pure_button')"));
      expect(sheetSrc, contains("ValueKey('video_sheet_screenshot_subtitled_button')"));
      expect(sheetSrc, contains('ScreenshotCaptureMode.pureVideo'));
      expect(sheetSrc, contains('ScreenshotCaptureMode.withSubtitles'));

      final pageSrc = _stripDartComments(
        File(p.join(repoRoot, 'lib/presentation/video/embedded_video_page.dart'))
            .readAsStringSync(),
      );
      expect(pageSrc, contains('portraitRotationFallbackTimeout'));
      expect(pageSrc, contains('_portraitRotationWaitExpired'));
      expect(
        pageSrc,
        isNot(contains('TestWidgetsFlutterBinding')),
        reason: '严禁用测试绑定判定绕过竖屏旋转降级逻辑',
      );
    });

    test('6. [#16] 全仓零分层逆向导入、零全局可变静态字段与顶层可变集合', () {
      final reverseImports = <String>[];
      final mutableStatics = <String>[];

      final importRegex = RegExp(r'''^\s*import\s+['"]([^'"]+)['"]''');
      // 匹配类内非 const、非 final、非方法/getter/setter 的静态可变字段。
      final staticMutableFieldRegex = RegExp(
        r'^\s+static\s+(?!const\b)(?!final\b)(?!void\b)(?!Future\b)(?!Stream\b)(?!bool\s+\w+\s*\()(?![A-Za-z0-9_<>?, ]+\s+(?:get|set)\s+)(?![A-Za-z0-9_<>?, ]+\s+\w+\s*\()[A-Za-z0-9_<>?,\s]+\s+[A-Za-z_]\w*\s*(?:=|;)',
      );
      // 匹配 static final 可变集合/缓存/单例句柄。
      final staticFinalMutableRegex = RegExp(
        r'^\s+static\s+final\s+.*(?:\b(?:Set|Map|List|LinkedHashMap|LinkedHashSet|Queue|Expando|StreamController|ValueNotifier|ChangeNotifier|DomainCooldownRegistry|KonataModalLayerRegistry)\b|<\s*[A-Za-z0-9_?, ]+>\s*(?:\{\}|\[\])|\bshared\b|\binstance\b)',
      );
      // 匹配顶层非 const、非 final 变量，或顶层可变集合/Expando。
      final topLevelMutableVarRegex = RegExp(
        r'^(?:var|late\s+(?!final)|(?:Map|Set|List|Expando|int|double|bool|String|Directory|File)\??\s+[A-Za-z_]\w*\s*(?:=|;))',
      );
      final topLevelMutableFinalRegex = RegExp(
        r'^final\s+(?!.*Provider(?:<|\())(?:(?:Map|Set|List|LinkedHashMap|LinkedHashSet|Expando)\b|.*=\s*(?:<[^>]+>\s*[\{\[]|\{\s*\}|\[\s*\]|Expando\b))',
      );

      for (final file in allLibFiles) {
        final rel = _relPath(repoRoot, file.path);
        if (rel.endsWith('.g.dart')) continue;
        final raw = file.readAsStringSync();
        final stripped = _stripDartComments(raw);
        final codeOnly = _stripDartComments(raw, blankStrings: true);
        final lines = stripped.split('\n');
        final codeLines = codeOnly.split('\n');

        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          final codeLine = codeLines[i];
          final imp = importRegex.firstMatch(line);
          if (imp != null) {
            final uri = imp.group(1)!;
            if (rel.startsWith('lib/application/') && uri.contains('presentation/')) {
              reverseImports.add('$rel:${i + 1}: $uri');
            } else if (rel.startsWith('lib/infrastructure/') &&
                (uri.contains('application/') || uri.contains('presentation/'))) {
              reverseImports.add('$rel:${i + 1}: $uri');
            } else if (rel.startsWith('lib/domain/') &&
                (uri.contains('application/') ||
                    uri.contains('presentation/') ||
                    uri.contains('infrastructure/'))) {
              reverseImports.add('$rel:${i + 1}: $uri');
            }
          }

          if (staticMutableFieldRegex.hasMatch(codeLine)) {
            mutableStatics.add('static mutable $rel:${i + 1}: ${line.trim()}');
          }
          if (staticFinalMutableRegex.hasMatch(codeLine)) {
            // 豁免只读不可变结构（如 RegExp / Paint / .unmodifiable / UnmodifiableView / Win32 只读 FFI 绑定）。
            final t = line.trim();
            final isImmutableLiteral =
                t.contains('RegExp(') ||
                t.contains('Paint()') ||
                t.contains('Unmodifiable') ||
                t.contains('.unmodifiable(') ||
                t.contains('Win32FfiBindings? instance');
            if (!isImmutableLiteral) {
              mutableStatics.add('static final mutable $rel:${i + 1}: $t');
            }
          }
          if (topLevelMutableVarRegex.hasMatch(codeLine)) {
            mutableStatics.add('top-level mutable $rel:${i + 1}: ${line.trim()}');
          }
          if (topLevelMutableFinalRegex.hasMatch(codeLine)) {
            final t = line.trim();
            if (!t.contains('Unmodifiable') && !t.contains('.unmodifiable(')) {
              mutableStatics.add('top-level final mutable $rel:${i + 1}: $t');
            }
          }
        }
      }

      expect(
        reverseImports,
        isEmpty,
        reason: '存在违规分层逆向导入：\n${reverseImports.join('\n')}',
      );
      expect(
        mutableStatics,
        isEmpty,
        reason: '存在全局可变静态或顶层可变状态：\n${mutableStatics.join('\n')}',
      );
    });

    test('7. [#17, #18, #19] 文件体量、空异常捕获、表现层硬编码魔法值与孤儿文件全部清零', () {
      final overLimitFiles = <String>[];
      final emptyCatches = <String>[];
      final presentationViolations = <String>[];

      final emptyOnRegex = RegExp(
        r'\bon\s+[A-Za-z0-9_<>?.,\s]+(?:\s+catch\s*\([^)]*\))?\s*\{\s*\}',
        multiLine: true,
      );
      final emptyCatchRegex = RegExp(r'\bcatch\s*\([^)]*\)\s*\{\s*\}', multiLine: true);
      final bareColorHexRegex = RegExp(r'\bColor\s*\(\s*0x[0-9A-Fa-f]+\s*\)');
      final bareWhiteBlackRegex = RegExp(r'\bColors\.(?:white|black)\b');
      final bareBlurRegex = RegExp(r'\bImageFilter\.blur\s*\(');
      final bareDurationRegex = RegExp(r'\bDuration\s*\(');
      final bareBorderRadiusRegex = RegExp(r'\bBorderRadius\.circular\s*\(\s*\d');

      for (final file in allLibFiles) {
        final rel = _relPath(repoRoot, file.path);
        if (rel.endsWith('.g.dart')) continue;
        final raw = file.readAsStringSync();
        final lineCount = raw.split('\n').length;

        final isExemptAlgorithmOrTable =
            rel.startsWith('lib/domain/scraping/') ||
            rel.startsWith('lib/domain/parsing/') ||
            rel.startsWith('lib/domain/matching/') ||
            rel.startsWith('lib/application/scraping/') ||
            rel.startsWith('lib/domain/text/') ||
            rel.contains('opencc_');
        if (!isExemptAlgorithmOrTable && lineCount > 1200) {
          overLimitFiles.add('$rel ($lineCount 行)');
        }

        final stripped = _stripDartComments(raw);
        for (final m in emptyOnRegex.allMatches(stripped)) {
          emptyCatches.add('$rel:${_lineOfOffset(stripped, m.start)}: ${m.group(0)!.trim()}');
        }
        for (final m in emptyCatchRegex.allMatches(stripped)) {
          emptyCatches.add('$rel:${_lineOfOffset(stripped, m.start)}: ${m.group(0)!.trim()}');
        }

        if (rel.startsWith('lib/presentation/') &&
            !rel.startsWith('lib/presentation/theme/')) {
          final lines = stripped.split('\n');
          for (var i = 0; i < lines.length; i++) {
            final line = lines[i];
            if (bareColorHexRegex.hasMatch(line)) {
              presentationViolations.add('Color(0x...) $rel:${i + 1}: ${line.trim()}');
            }
            if (bareWhiteBlackRegex.hasMatch(line)) {
              presentationViolations.add('Colors.white/black $rel:${i + 1}: ${line.trim()}');
            }
            if (bareBlurRegex.hasMatch(line)) {
              presentationViolations.add('ImageFilter.blur $rel:${i + 1}: ${line.trim()}');
            }
            if (bareDurationRegex.hasMatch(line)) {
              presentationViolations.add('Duration(...) $rel:${i + 1}: ${line.trim()}');
            }
            if (bareBorderRadiusRegex.hasMatch(line)) {
              presentationViolations.add('BorderRadius.circular(<num>) $rel:${i + 1}: ${line.trim()}');
            }
          }
        }
      }

      // 孤儿文件检测：除入口文件与被父库 part 引入的分片外，所有 lib/ 文件必须被 lib/ 内其他文件引用。
      final referencedTargets = <String>{
        'lib/main.dart',
        'lib/main_android.dart',
      };
      final directiveRegex = RegExp(r'''^\s*(?:import|export|part)\s+['"]([^'"]+)['"]''');
      for (final file in allLibFiles) {
        final rel = _relPath(repoRoot, file.path);
        final dirRel = p.posix.dirname(rel);
        final stripped = _stripDartComments(file.readAsStringSync());
        for (final line in stripped.split('\n')) {
          final m = directiveRegex.firstMatch(line);
          if (m == null) continue;
          final uri = m.group(1)!;
          if (uri.startsWith('dart:') || uri.startsWith('package:')) {
            if (uri.startsWith('package:konata/')) {
              referencedTargets.add('lib/${uri.substring('package:konata/'.length)}');
            }
            continue;
          }
          final resolved = p.posix.normalize(p.posix.join(dirRel, uri));
          referencedTargets.add(resolved);
        }
      }

      final orphanFiles = <String>[];
      for (final file in allLibFiles) {
        final rel = _relPath(repoRoot, file.path);
        if (!referencedTargets.contains(rel)) {
          orphanFiles.add(rel);
        }
      }

      expect(overLimitFiles, isEmpty, reason: '存在超过 1200 行上限的非刮削文件：\n${overLimitFiles.join('\n')}');
      expect(emptyCatches, isEmpty, reason: '存在无日志空异常捕获块：\n${emptyCatches.join('\n')}');
      expect(
        presentationViolations,
        isEmpty,
        reason: '表现层（theme/ 外）存在硬编码视觉魔法值（共 ${presentationViolations.length} 处）：\n${presentationViolations.take(40).join('\n')}',
      );
      expect(orphanFiles, isEmpty, reason: '存在 0 引用的孤儿 .dart 文件：\n${orphanFiles.join('\n')}');

      expect(
        File(p.join(repoRoot, 'lib/presentation/widgets/design_system/konata_settings_row.dart'))
            .existsSync(),
        isFalse,
      );
      final sharedAssets = File(p.join(repoRoot, '.agent-work/SHARED_ASSETS.md'));
      if (sharedAssets.existsSync()) {
        expect(sharedAssets.readAsStringSync(), isNot(contains('konata_settings_row.dart')));
      }
    });

    test('8. [#22] 全片库扩展名白名单与片源标签唯一收口', () {
      expect(KonataMediaExtensions.video, containsAll(['.ogm', '.rmvb', '.iso']));
      expect(
        KonataMediaExtensions.sourceTags,
        containsAll(['bdrip', 'dvdrip', 'ldrip', 'tvrip', 'hdtv', 'webrip', 'web-dl']),
      );

      final techParserSrc = File(
        p.join(repoRoot, 'lib/domain/parsing/media_tech_parser.dart'),
      ).readAsStringSync();
      expect(techParserSrc, contains('KonataMediaExtensions.sourceTagAlternation'));

      final personalParserSrc = File(
        p.join(repoRoot, 'lib/domain/scraping/personal_filename_parser.dart'),
      ).readAsStringSync();
      expect(personalParserSrc, contains('KonataMediaExtensions.sourceTagAlternation'));
      expect(personalParserSrc, contains('KonataMediaExtensions.explicitSourceTagAlternation'));

      final sideSheetSrc = File(
        p.join(repoRoot, 'lib/presentation/video/video_side_sheet.dart'),
      ).readAsStringSync();
      expect(sideSheetSrc, contains('KonataMediaExtensions.subtitleExtensionsNoDot'));
    });

    test('9. [#20] 北极星基准含真实 seek_recovery_us 采样，Windows A/B 含材质/小窗/弹窗共存断言', () {
      final northstarSrc = File(
        p.join(repoRoot, 'integration_test/playback_northstar_benchmark_test.dart'),
      ).readAsStringSync();
      expect(northstarSrc, contains('seek_recovery_us'));
      expect(northstarSrc, contains('seek_recovery_median_us'));
      expect(northstarSrc, contains('seekAbsolute'));
      expect(northstarSrc, contains('zero_null_vo_ao_verified'));

      final abSrc = File(
        p.join(repoRoot, 'integration_test/windows_video_backend_ab_test.dart'),
      ).readAsStringSync();
      expect(abSrc, contains('KonataWindowMaterial.acrylic'));
      expect(abSrc, contains('KonataFloatingMiniPlayer'));
      expect(abSrc, contains('windows_underlay_cutout_surface'));
      expect(abSrc, contains('showKonataGlassDialog'));
      expect(abSrc, contains('coexistenceVerification'));
    });
  });
}
