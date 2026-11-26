import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Konata v3 多包工作区统一门禁与增量验证运行器（纯 `dart:*` 零外部依赖）。
///
/// 支持子命令：
/// - `guard`：校验跨包单向 DAG、内部路径禁令、禁用依赖与车道写权限白名单
/// - `changed`：仅对当前改动及受影响包执行 `guard + analyze + test`
/// - `analyze [路径...]`：对全仓或指定包执行静态分析（90 秒超时）
/// - `test [包或测试路径...]`：纯 Dart 包走 `dart test`，Flutter 包走 `flutter test`（180 秒超时）
/// - `build`：在 `apps/konata` 执行 Windows Debug 构建校验（240 秒超时）
/// - `all`：串行执行 `guard -> analyze -> test -> build`（完成或超时触发提示音）
Future<void> main(List<String> args) async {
  if (args.isEmpty || args.first == '-h' || args.first == '--help') {
    _printUsage();
    exitCode = args.isEmpty ? 64 : 0;
    return;
  }

  final repoRoot = _resolveRepoRoot();
  final command = args.first;
  final extraArgs = args.sublist(1);

  switch (command) {
    case 'guard':
      exitCode = await _runGuard(repoRoot);
    case 'changed':
      exitCode = await _runChanged(repoRoot);
    case 'analyze':
      exitCode = await _runAnalyze(repoRoot, extraArgs);
    case 'test':
      exitCode = await _runTest(repoRoot, extraArgs);
    case 'build':
      if (extraArgs.isNotEmpty) {
        stderr.writeln('提示：build 子命令不接收额外参数，将忽略：${extraArgs.join(' ')}');
      }
      exitCode = await _runBuild(repoRoot);
    case 'all':
      if (extraArgs.isNotEmpty) {
        stderr.writeln('错误：all 子命令不接受额外参数：${extraArgs.join(' ')}');
        _printUsage();
        exitCode = 64;
        return;
      }
      exitCode = await _runAll(repoRoot);
    default:
      stderr.writeln('错误：未知子命令 "$command"。');
      _printUsage();
      exitCode = 64;
  }
}

/// 单个工作区成员包的元信息模型。
final class _WorkspacePackage {
  const _WorkspacePackage({
    required this.name,
    required this.relPath,
    required this.absPath,
    required this.layer,
    required this.usesFlutter,
    required this.dependencies,
  });

  final String name;
  final String relPath;
  final String absPath;
  final _PackageLayer layer;
  final bool usesFlutter;
  final Set<String> dependencies;
}

/// 18 包分层枚举，用于硬拦截跨包单向依赖方向。
enum _PackageLayer {
  app,
  contracts,
  storage,
  designSystem,
  engine,
  feature,
  other,
}

/// 串行执行全套交付门禁流程，任一阶段失败立即终止。
Future<int> _runAll(Directory repoRoot) async {
  final steps = <({String label, Future<int> Function() action})>[
    (label: '阶段 1/4 · 架构边界守门 (guard)', action: () => _runGuard(repoRoot)),
    (
      label: '阶段 2/4 · 全仓静态分析 (analyze)',
      action: () => _runAnalyze(repoRoot, const []),
    ),
    (
      label: '阶段 3/4 · 全量分层测试 (test)',
      action: () => _runTest(repoRoot, const []),
    ),
    (label: '阶段 4/4 · Windows Debug 构建 (build)', action: () => _runBuild(repoRoot)),
  ];

  for (final step in steps) {
    stdout.writeln('>>> ${step.label}');
    final code = await step.action();
    if (code != 0) {
      await _playBeep();
      return code;
    }
  }

  await _playBeep();
  stdout.writeln('✅ 全部门禁检查已通过 (guard -> analyze -> test -> build)。');
  return 0;
}

/// 执行架构边界与车道写权限硬拦截，并输出非阻断体量软提醒。
Future<int> _runGuard(Directory repoRoot) async {
  final stopwatch = Stopwatch()..start();
  final packages = _discoverWorkspacePackages(repoRoot);
  final byName = {for (final pkg in packages) pkg.name: pkg};
  final errors = <String>[];
  final warnings = <String>[];

  // 1. 校验根与各包 pubspec.yaml 严禁引入代码生成依赖。
  const forbiddenDeps = {
    'build_runner',
    'drift',
    'drift_dev',
    'freezed',
    'freezed_annotation',
    'json_serializable',
    'riverpod_generator',
  };
  final pubspecTargets = <File>[
    File(_join(repoRoot.path, 'pubspec.yaml')),
    for (final pkg in packages) File(_join(pkg.absPath, 'pubspec.yaml')),
  ];
  for (final pubspec in pubspecTargets) {
    if (!pubspec.existsSync()) continue;
    final deps = _extractDeclaredPackages(pubspec.readAsStringSync());
    final rel = _relativePosix(repoRoot.path, pubspec.path);
    for (final dep in deps) {
      if (forbiddenDeps.contains(dep)) {
        errors.add('$rel: 禁止引入受限代码生成或废弃持久化依赖 `$dep`');
      }
    }
  }

  // 2. 扫描各成员包源码，拦截非法跨包依赖与内部路径渗透。
  for (final pkg in packages) {
    final scanRoots = <Directory>[
      Directory(_join(pkg.absPath, 'lib')),
      Directory(_join(pkg.absPath, 'test')),
    ];
    for (final root in scanRoots) {
      if (!root.existsSync()) continue;
      final isTestDir = root.path.endsWith('${Platform.pathSeparator}test');
      for (final entity in root.listSync(recursive: true, followLinks: false)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final relFile = _relativePosix(repoRoot.path, entity.path);
        final content = entity.readAsStringSync();
        final uris = _extractDirectiveUris(content);

        var internalImportCount = 0;
        for (final uri in uris) {
          if (!uri.startsWith('dart:') && !uri.startsWith('package:')) {
            internalImportCount++;
          }
          _validateImport(
            pkg: pkg,
            byName: byName,
            relFile: relFile,
            uri: uri,
            isTestDir: isTestDir,
            errors: errors,
          );
        }

        // 仅对非测试、非算法词表文件输出柔和体量提醒，绝不阻断。
        if (!isTestDir && !_isAlgorithmOrDictionaryExempt(relFile)) {
          final lines = content.split('\n');
          if (lines.length > 800) {
            warnings.add('$relFile: 文件共 ${lines.length} 行（软提醒阈值 800 行，可评估自然拆分）');
          }
          if (internalImportCount > 18) {
            warnings.add('$relFile: 内部导入扇出 $internalImportCount 个（软提醒阈值 18 个）');
          }
        }
      }
    }
  }

  // 3. 校验当前 Worktree 车道私有写权限白名单（`<git-dir>/konata-lane.json`）。
  await _validateLaneWhitelist(repoRoot, errors);

  stopwatch.stop();
  for (final warning in warnings) {
    stdout.writeln('⚠️ 软提醒：$warning');
  }
  if (errors.isNotEmpty) {
    stderr.writeln('❌ [边界守门 (guard)] 发现 ${errors.length} 项违规：');
    for (final error in errors) {
      stderr.writeln('  - $error');
    }
    return 1;
  }

  stdout.writeln(
    '✅ [边界守门 (guard)] 通过（已扫描 ${packages.length} 个工作区包，耗时 ${(stopwatch.elapsedMilliseconds / 1000).toStringAsFixed(2)} 秒）。',
  );
  return 0;
}

/// 根据分层矩阵逐条校验单条 `import` / `export` 指令。
void _validateImport({
  required _WorkspacePackage pkg,
  required Map<String, _WorkspacePackage> byName,
  required String relFile,
  required String uri,
  required bool isTestDir,
  required List<String> errors,
}) {
  // 纯 Dart 底座与无 UI 引擎严禁接触 Flutter UI 或图形上下文。
  final isPureDartLayer = pkg.layer == _PackageLayer.contracts ||
      pkg.layer == _PackageLayer.storage ||
      pkg.layer == _PackageLayer.engine;
  if (isPureDartLayer) {
    if (uri == 'dart:ui' ||
        uri.startsWith('package:flutter/') ||
        uri.startsWith('package:flutter_test/') ||
        uri.startsWith('package:material_ui/') ||
        uri.startsWith('package:cupertino_ui/')) {
      errors.add('$relFile: 纯 Dart 包 `${pkg.name}` 禁止导入 `$uri`');
      return;
    }
  }

  // 底座与引擎均禁止引入 Riverpod。
  final isRiverpodUri =
      uri.startsWith('package:flutter_riverpod/') || uri.startsWith('package:riverpod/');
  if (isRiverpodUri) {
    if (pkg.layer == _PackageLayer.contracts ||
        pkg.layer == _PackageLayer.storage ||
        pkg.layer == _PackageLayer.designSystem ||
        pkg.layer == _PackageLayer.engine) {
      errors.add('$relFile: 包 `${pkg.name}` 禁止依赖 Riverpod（`$uri`）');
      return;
    }
    // Feature 业务状态机与数据层保持 0 Ref，Riverpod 仅留在外层 providers / manifest / ui。
    if (pkg.layer == _PackageLayer.feature &&
        !isTestDir &&
        (relFile.contains('/lib/src/state/') || relFile.contains('/lib/src/data/'))) {
      errors.add('$relFile: Feature 状态与数据层禁止依赖 Riverpod，请改用构造函数注入（`$uri`）');
      return;
    }
  }

  // Feature 业务界面隔离 Material / Cupertino 具体控件库。
  if (pkg.layer == _PackageLayer.feature &&
      (uri == 'package:flutter/material.dart' ||
          uri == 'package:flutter/cupertino.dart' ||
          uri.startsWith('package:material_ui/') ||
          uri.startsWith('package:cupertino_ui/'))) {
    errors.add('$relFile: Feature 包禁止直接导入 `$uri`，请通过 `konata_design_system` 复用组件');
    return;
  }

  if (!uri.startsWith('package:')) return;
  final slashIndex = uri.indexOf('/');
  if (slashIndex <= 'package:'.length) return;
  final targetPkgName = uri.substring('package:'.length, slashIndex);
  final targetSubPath = uri.substring(slashIndex + 1);
  if (targetPkgName == pkg.name) return;

  final targetPkg = byName[targetPkgName];
  if (targetPkg == null) return;

  // 跨包仅允许通过唯一公开出口 `package:<pkg>/<pkg>.dart` 访问。
  if (targetSubPath.startsWith('src/')) {
    errors.add('$relFile: 严禁跨包导入内部路径 `$uri`，请仅导入 `package:$targetPkgName/$targetPkgName.dart`');
    return;
  }

  // 校验包间单向 DAG。
  final allowed = switch (pkg.layer) {
    _PackageLayer.contracts => false,
    _PackageLayer.storage => targetPkg.layer == _PackageLayer.contracts,
    _PackageLayer.designSystem => targetPkg.layer == _PackageLayer.contracts,
    _PackageLayer.engine => targetPkg.layer == _PackageLayer.contracts ||
        targetPkg.layer == _PackageLayer.storage ||
        targetPkg.layer == _PackageLayer.engine,
    _PackageLayer.feature => targetPkg.layer == _PackageLayer.contracts ||
        targetPkg.layer == _PackageLayer.storage ||
        targetPkg.layer == _PackageLayer.designSystem ||
        targetPkg.layer == _PackageLayer.engine,
    _PackageLayer.app => true,
    _PackageLayer.other => true,
  };
  if (!allowed) {
    errors.add('$relFile: 非法跨包依赖 `${pkg.name}` (${pkg.layer.name}) -> `${targetPkg.name}` (${targetPkg.layer.name})');
  }
}

/// 校验当前工作树私有白名单配置 `<git-dir>/konata-lane.json` 是否存在越界改动。
Future<void> _validateLaneWhitelist(
  Directory repoRoot,
  List<String> errors,
) async {
  final gitDirRes = await Process.run(
    'git',
    ['rev-parse', '--git-dir'],
    workingDirectory: repoRoot.path,
  );
  if (gitDirRes.exitCode != 0) return;

  final rawGitDir = (gitDirRes.stdout as String).trim();
  final gitDir = Directory(rawGitDir).isAbsolute
      ? Directory(rawGitDir)
      : Directory(_join(repoRoot.path, rawGitDir));
  final laneFile = File(_join(gitDir.path, 'konata-lane.json'));
  if (!laneFile.existsSync()) return;

  final decoded = jsonDecode(laneFile.readAsStringSync());
  if (decoded is! Map<String, dynamic>) {
    errors.add('车道白名单文件格式无效：${laneFile.path}');
    return;
  }
  final allowList = (decoded['allow'] as List<dynamic>? ?? const [])
      .map((item) => item.toString().replaceAll('\\', '/').trim())
      .where((item) => item.isNotEmpty)
      .toList();
  if (allowList.isEmpty) return;

  final baseRef = (decoded['base'] as String?)?.trim() ?? 'main';
  final changedFiles = await _collectChangedPaths(repoRoot, baseRef: baseRef);
  for (final path in changedFiles) {
    final allowed = allowList.any((prefix) {
      final normalized = prefix.endsWith('/') ? prefix : '$prefix/';
      return path == prefix || path.startsWith(normalized);
    });
    if (!allowed) {
      errors.add('车道白名单越界修改：$path（当前车道仅授权：${allowList.join(', ')}）');
    }
  }
}

/// 仅对当前改动及直接下游受影响包执行 `guard -> analyze -> test`。
Future<int> _runChanged(Directory repoRoot) async {
  final guardCode = await _runGuard(repoRoot);
  if (guardCode != 0) return guardCode;

  final packages = _discoverWorkspacePackages(repoRoot);
  final changedFiles = await _collectChangedPaths(repoRoot, baseRef: 'main');
  if (changedFiles.isEmpty) {
    stdout.writeln('✅ [增量验证 (changed)] 未检测到待验证改动文件。');
    return 0;
  }

  final affected = <String>{};
  var rootConfigTouched = false;
  for (final rel in changedFiles) {
    if (rel == 'pubspec.yaml' || rel == 'analysis_options.yaml') {
      rootConfigTouched = true;
      break;
    }
    for (final pkg in packages) {
      if (rel == pkg.relPath || rel.startsWith('${pkg.relPath}/')) {
        affected.add(pkg.name);
      }
    }
  }

  if (rootConfigTouched) {
    affected.addAll(packages.map((p) => p.name));
  } else {
    // 若底座或引擎变动，连带将直接依赖它的包纳入回归范围。
    final directSeeds = Set<String>.from(affected);
    for (final pkg in packages) {
      if (pkg.dependencies.any(directSeeds.contains)) {
        affected.add(pkg.name);
      }
    }
  }

  if (affected.isEmpty) {
    stdout.writeln('✅ [增量验证 (changed)] 仅改动非工作区包文件，边界守门已通过。');
    return 0;
  }

  final targetPackages =
      packages.where((p) => affected.contains(p.name)).toList();
  stdout.writeln(
    '==> [增量验证 (changed)] 受影响包：${targetPackages.map((p) => p.name).join(', ')}',
  );

  final analyzeCode = await _runAnalyze(
    repoRoot,
    targetPackages.map((p) => p.relPath).toList(),
  );
  if (analyzeCode != 0) return analyzeCode;

  return _runTest(
    repoRoot,
    targetPackages.map((p) => p.relPath).toList(),
  );
}

/// 执行静态分析（统一使用同 SDK 下 `dart analyze`，90 秒超时）。
Future<int> _runAnalyze(Directory repoRoot, List<String> targets) async {
  final dartBin = Platform.resolvedExecutable;
  final analyzeArgs = targets.isEmpty ? const ['analyze'] : ['analyze', ...targets];
  return _runProcessStep(
    executable: dartBin,
    arguments: analyzeArgs,
    workingDirectory: repoRoot.path,
    label: '静态代码分析 (analyze)',
    timeout: const Duration(seconds: 90),
  );
}

/// 按包属性自动分流纯 Dart 包 (`dart test`) 与 Flutter 包 (`flutter test`)。
Future<int> _runTest(Directory repoRoot, List<String> targets) async {
  final packages = _discoverWorkspacePackages(repoRoot);
  final dartBin = Platform.resolvedExecutable;
  final flutterBin = _resolveFlutterExecutable();
  if (flutterBin == null) {
    stderr.writeln('错误：无法定位与当前 Dart 运行时同源的 flutter 可执行文件。');
    return 1;
  }

  final invocations = <({
    _WorkspacePackage pkg,
    List<String> extraArgs,
  })>[];

  if (targets.isEmpty) {
    for (final pkg in packages) {
      if (Directory(_join(pkg.absPath, 'test')).existsSync()) {
        invocations.add((pkg: pkg, extraArgs: const []));
      }
    }
  } else {
    for (final rawTarget in targets) {
      final normalized = rawTarget.replaceAll('\\', '/').replaceFirst(RegExp(r'^\./'), '');
      final matched = _matchPackageForTarget(packages, normalized);
      if (matched == null) {
        stderr.writeln('错误：无法将测试目标 `$rawTarget` 归属到任何工作区包。');
        return 64;
      }
      if (normalized == matched.relPath || normalized == matched.name) {
        if (Directory(_join(matched.absPath, 'test')).existsSync()) {
          invocations.add((pkg: matched, extraArgs: const []));
        }
      } else {
        final subPath = normalized.startsWith('${matched.relPath}/')
            ? normalized.substring(matched.relPath.length + 1)
            : normalized;
        invocations.add((pkg: matched, extraArgs: [subPath]));
      }
    }
  }

  if (invocations.isEmpty) {
    stdout.writeln('提示：当前工作区尚无包含 `test/` 目录的目标包，跳过测试执行。');
    return 0;
  }

  for (final item in invocations) {
    final useFlutter = item.pkg.usesFlutter;
    final bin = useFlutter ? flutterBin : dartBin;
    final label = useFlutter
        ? 'Flutter 测试 [${item.pkg.name}]'
        : '纯 Dart 测试 [${item.pkg.name}]';
    final code = await _runProcessStep(
      executable: bin,
      arguments: ['test', ...item.extraArgs],
      workingDirectory: item.pkg.absPath,
      label: label,
      timeout: const Duration(seconds: 180),
    );
    if (code != 0) return code;
  }
  return 0;
}

/// 在 `apps/konata` 下执行 Windows Debug 构建校验，存在本地密钥定义文件时自动注入。
Future<int> _runBuild(Directory repoRoot) async {
  final flutterBin = _resolveFlutterExecutable();
  if (flutterBin == null) {
    stderr.writeln('错误：无法定位与当前 Dart 运行时同源的 flutter 可执行文件。');
    return 1;
  }

  final appDir = Directory(_join(repoRoot.path, 'apps/konata'));
  if (!appDir.existsSync()) {
    stderr.writeln('错误：找不到应用壳目录：${appDir.path}');
    return 1;
  }

  final args = <String>['build', 'windows', '--debug'];
  final rootDefines = File(_join(repoRoot.path, 'dart_defines.dev.json'));
  final appDefines = File(_join(appDir.path, 'dart_defines.dev.json'));
  if (appDefines.existsSync()) {
    args.add('--dart-define-from-file=dart_defines.dev.json');
  } else if (rootDefines.existsSync()) {
    args.add('--dart-define-from-file=../../dart_defines.dev.json');
  }

  return _runProcessStep(
    executable: flutterBin,
    arguments: args,
    workingDirectory: appDir.path,
    label: 'Windows Debug 构建 (build)',
    timeout: const Duration(seconds: 240),
  );
}

/// 解析根 `pubspec.yaml` 的 `workspace:` 成员列表并加载各包元信息。
List<_WorkspacePackage> _discoverWorkspacePackages(Directory repoRoot) {
  final rootPubspec = File(_join(repoRoot.path, 'pubspec.yaml'));
  if (!rootPubspec.existsSync()) {
    return const [];
  }

  final memberPaths = <String>[];
  var inWorkspaceBlock = false;
  for (final rawLine in rootPubspec.readAsLinesSync()) {
    final trimmed = rawLine.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    if (!rawLine.startsWith(' ') && !rawLine.startsWith('\t')) {
      inWorkspaceBlock = trimmed == 'workspace:';
      continue;
    }
    if (inWorkspaceBlock && trimmed.startsWith('- ')) {
      final path = trimmed.substring(2).trim().replaceAll("'", '').replaceAll('"', '');
      if (path.isNotEmpty) {
        memberPaths.add(path.replaceAll('\\', '/'));
      }
    }
  }

  final result = <_WorkspacePackage>[];
  for (final relPath in memberPaths) {
    final absPath = _join(repoRoot.path, relPath);
    final pubspecFile = File(_join(absPath, 'pubspec.yaml'));
    if (!pubspecFile.existsSync()) continue;
    final content = pubspecFile.readAsStringSync();
    final nameMatch = RegExp(r'^name:\s*([a-zA-Z0-9_]+)', multiLine: true)
        .firstMatch(content);
    if (nameMatch == null) continue;
    final name = nameMatch.group(1)!;
    final deps = _extractDeclaredPackages(content);
    final usesFlutter = RegExp(r'^\s+sdk:\s*flutter\s*$', multiLine: true)
        .hasMatch(content);
    result.add(
      _WorkspacePackage(
        name: name,
        relPath: relPath,
        absPath: absPath,
        layer: _classifyLayer(relPath),
        usesFlutter: usesFlutter,
        dependencies: deps,
      ),
    );
  }
  return result;
}

/// 按目录路径将工作区成员包映射到分层枚举。
_PackageLayer _classifyLayer(String relPath) {
  if (relPath == 'apps/konata' || relPath.startsWith('apps/')) {
    return _PackageLayer.app;
  }
  if (relPath == 'packages/foundation/konata_contracts') {
    return _PackageLayer.contracts;
  }
  if (relPath == 'packages/foundation/konata_storage') {
    return _PackageLayer.storage;
  }
  if (relPath == 'packages/foundation/konata_design_system') {
    return _PackageLayer.designSystem;
  }
  if (relPath.startsWith('packages/engines/')) {
    return _PackageLayer.engine;
  }
  if (relPath.startsWith('packages/features/')) {
    return _PackageLayer.feature;
  }
  return _PackageLayer.other;
}

/// 从 `pubspec.yaml` 中提取 `dependencies` 与 `dev_dependencies` 顶层包名集合。
Set<String> _extractDeclaredPackages(String pubspecContent) {
  final deps = <String>{};
  var inDepsSection = false;
  for (final rawLine in pubspecContent.split('\n')) {
    final trimmed = rawLine.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    if (!rawLine.startsWith(' ') && !rawLine.startsWith('\t')) {
      inDepsSection =
          trimmed == 'dependencies:' || trimmed == 'dev_dependencies:';
      continue;
    }
    if (!inDepsSection) continue;
    final match = RegExp(r'^  ([a-zA-Z0-9_]+):').firstMatch(rawLine);
    if (match != null) {
      deps.add(match.group(1)!);
    }
  }
  return deps;
}

/// 从 Dart 源码中提取所有 `import` / `export` 目标 URI。
List<String> _extractDirectiveUris(String source) {
  final uris = <String>[];
  final pattern = RegExp(
    r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''',
    multiLine: true,
  );
  for (final match in pattern.allMatches(source)) {
    final uri = match.group(1);
    if (uri != null && uri.isNotEmpty) {
      uris.add(uri);
    }
  }
  return uris;
}

/// 判断文件是否属于刮削算法或大词表豁免清单（免于行数与扇出软提醒）。
bool _isAlgorithmOrDictionaryExempt(String relFile) {
  return relFile.startsWith('packages/engines/engine_scraping/') ||
      relFile.contains('dictionary') ||
      relFile.contains('vocab') ||
      relFile.contains('_table.dart');
}

/// 收集工作区未提交变动与相对基准分支已提交变动的相对路径集合。
Future<Set<String>> _collectChangedPaths(
  Directory repoRoot, {
  required String baseRef,
}) async {
  final changed = <String>{};

  final statusRes = await Process.run(
    'git',
    ['status', '--porcelain', '-uall'],
    workingDirectory: repoRoot.path,
  );
  if (statusRes.exitCode == 0) {
    for (final line in (statusRes.stdout as String).split('\n')) {
      if (line.length < 4) continue;
      var pathPart = line.substring(3).trim();
      final arrowIdx = pathPart.indexOf(' -> ');
      if (arrowIdx >= 0) {
        pathPart = pathPart.substring(arrowIdx + 4).trim();
      }
      pathPart = pathPart.replaceAll('"', '').replaceAll('\\', '/');
      if (pathPart.isNotEmpty) {
        changed.add(pathPart);
      }
    }
  }

  final branchRes = await Process.run(
    'git',
    ['branch', '--show-current'],
    workingDirectory: repoRoot.path,
  );
  final currentBranch = (branchRes.stdout as String).trim();
  if (currentBranch.isNotEmpty && currentBranch != baseRef) {
    final diffRes = await Process.run(
      'git',
      ['diff', '--name-only', '$baseRef...HEAD'],
      workingDirectory: repoRoot.path,
    );
    if (diffRes.exitCode == 0) {
      for (final line in (diffRes.stdout as String).split('\n')) {
        final trimmed = line.trim().replaceAll('\\', '/');
        if (trimmed.isNotEmpty) {
          changed.add(trimmed);
        }
      }
    }
  }

  return changed;
}

/// 按最长前缀优先将命令行目标匹配至所属工作区包。
_WorkspacePackage? _matchPackageForTarget(
  List<_WorkspacePackage> packages,
  String normalizedTarget,
) {
  _WorkspacePackage? best;
  for (final pkg in packages) {
    if (normalizedTarget == pkg.name ||
        normalizedTarget == pkg.relPath ||
        normalizedTarget.startsWith('${pkg.relPath}/')) {
      if (best == null || pkg.relPath.length > best.relPath.length) {
        best = pkg;
      }
    }
  }
  return best;
}

/// 启动子进程并实时透传输出，超时后强制终止整棵子进程树防止锁文件残留。
Future<int> _runProcessStep({
  required String executable,
  required List<String> arguments,
  required String workingDirectory,
  required String label,
  required Duration timeout,
}) async {
  stdout.writeln(
    '==> [$label] ($workingDirectory) 执行：${arguments.join(' ')}（超时上限 ${timeout.inSeconds} 秒）',
  );
  final stopwatch = Stopwatch()..start();

  final process = await Process.start(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    runInShell: Platform.isWindows && executable.toLowerCase().endsWith('.bat'),
  );

  final stdoutDone = Completer<void>();
  final stderrDone = Completer<void>();

  process.stdout.listen(
    stdout.add,
    onDone: () {
      if (!stdoutDone.isCompleted) stdoutDone.complete();
    },
    onError: (_) {
      if (!stdoutDone.isCompleted) stdoutDone.complete();
    },
  );
  process.stderr.listen(
    stderr.add,
    onDone: () {
      if (!stderrDone.isCompleted) stderrDone.complete();
    },
    onError: (_) {
      if (!stderrDone.isCompleted) stderrDone.complete();
    },
  );

  var timedOut = false;
  final timer = Timer(timeout, () {
    timedOut = true;
    unawaited(_terminateProcessTree(process));
  });

  final code = await process.exitCode;
  timer.cancel();
  await Future.wait([stdoutDone.future, stderrDone.future]);
  await stdout.flush();
  await stderr.flush();
  stopwatch.stop();

  if (timedOut) {
    stderr.writeln(
      '❌ [$label] 超过 ${timeout.inSeconds} 秒上限，已强杀子进程树 (PID=${process.pid})。',
    );
    await _playBeep();
    return 124;
  }

  if (code == 0) {
    stdout.writeln(
      '✅ [$label] 通过，耗时 ${(stopwatch.elapsedMilliseconds / 1000).toStringAsFixed(1)} 秒。',
    );
  } else {
    stderr.writeln('❌ [$label] 失败，退出码：$code。');
  }
  return code;
}

/// 基于当前脚本位置反推仓库根目录，避免调用目录偏移导致路径错乱。
Directory _resolveRepoRoot() {
  final scriptFile = File.fromUri(Platform.script);
  if (scriptFile.existsSync()) {
    return scriptFile.parent.parent.absolute;
  }
  return Directory.current.absolute;
}

/// 基于当前 Dart 可执行文件路径查找同源 Flutter SDK 的可执行文件。
String? _resolveFlutterExecutable() {
  final targetName = Platform.isWindows ? 'flutter.bat' : 'flutter';
  var current = File(Platform.resolvedExecutable).parent;

  for (var depth = 0; depth < 6; depth++) {
    final direct = File(_join(current.path, targetName));
    if (direct.existsSync()) return direct.path;
    final nestedBin = File(_join(current.path, 'bin/$targetName'));
    if (nestedBin.existsSync()) return nestedBin.path;
    final parent = current.parent;
    if (parent.path == current.path) break;
    current = parent;
  }
  return null;
}

/// 在 Windows 下使用 `taskkill /F /T` 彻底结束整棵子进程树。
Future<void> _terminateProcessTree(Process process) async {
  if (Platform.isWindows) {
    try {
      await Process.run('taskkill', ['/F', '/T', '/PID', '${process.pid}']);
      return;
    } catch (_) {
      // 兜底交由原生信号终止。
    }
  }
  process.kill(ProcessSignal.sigkill);
}

/// 在全量门禁结束或超时熔断时触发轻量提示音。
Future<void> _playBeep() async {
  if (Platform.isWindows) {
    try {
      await Process.run(
        'powershell',
        ['-NoProfile', '-Command', '[console]::beep(880,300)'],
      );
      return;
    } catch (_) {}
  }
  stdout.write('\x07');
}

/// 跨平台拼接路径片段。
String _join(String base, String rel) {
  final cleanBase = base.replaceAll(RegExp(r'[\\/]+$'), '');
  final cleanRel = rel.replaceAll('/', Platform.pathSeparator);
  return '$cleanBase${Platform.pathSeparator}$cleanRel';
}

/// 计算相对仓库根的统一正斜杠路径。
String _relativePosix(String rootPath, String absPath) {
  final normRoot = rootPath.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
  final normAbs = absPath.replaceAll('\\', '/');
  if (normAbs.startsWith('$normRoot/')) {
    return normAbs.substring(normRoot.length + 1);
  }
  return normAbs;
}

/// 输出命令行使用说明。
void _printUsage() {
  stdout.writeln(
    '用法：dart run tool/verify.dart <guard|changed|analyze|test|build|all> [目标]\n'
    '  guard                  检查跨包单向边界、内部路径禁令、禁用依赖与车道白名单\n'
    '  changed                仅对改动及受影响包执行 guard -> analyze -> test\n'
    '  analyze [包路径...]    静态分析全仓或指定包（90 秒超时）\n'
    '  test [包或测试路径...] 自动分流 dart test / flutter test（180 秒超时）\n'
    '  build                  在 apps/konata 下执行 Windows Debug 构建（240 秒超时）\n'
    '  all                    串行执行 guard -> analyze -> test -> build（完成提示音）',
  );
}
