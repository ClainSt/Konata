import 'dart:async';
import 'dart:io';

/// 统一超时受控门禁运行器（纯 `dart:io` 实现，无外层脚本包装）。
///
/// 支持子命令：
/// - `analyze`：执行 `flutter analyze`（90 秒超时）
/// - `test [可选测试文件或目录参数...]`：执行 `flutter test`（180 秒超时）
/// - `build`：执行 `flutter build windows --debug`（240 秒超时）
/// - `all`：按顺序串行执行 `analyze` -> `test` -> `build`（完成或超时熔断时提示音）
Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    _printUsage();
    exitCode = 64;
    return;
  }

  final command = args.first;
  final extraArgs = args.sublist(1);
  final flutterBin = _resolveFlutterExecutable();
  if (flutterBin == null) {
    stderr.writeln(
      '错误：无法从当前 Dart 运行时（${Platform.resolvedExecutable}）定位同级或所属 SDK 的 flutter 工具。',
    );
    exitCode = 1;
    return;
  }

  switch (command) {
    case 'analyze':
      if (extraArgs.isNotEmpty) {
        stderr.writeln('提示：analyze 子命令不接收额外位置参数，将忽略多余参数：${extraArgs.join(' ')}');
      }
      exitCode = await _runStep(
        flutterBin: flutterBin,
        label: '静态代码分析 (analyze)',
        flutterArgs: const ['analyze'],
        timeout: const Duration(seconds: 90),
      );
    case 'test':
      exitCode = await _runStep(
        flutterBin: flutterBin,
        label: '自动化测试 (test)',
        flutterArgs: ['test', ...extraArgs],
        timeout: const Duration(seconds: 180),
      );
    case 'build':
      if (extraArgs.isNotEmpty) {
        stderr.writeln('提示：build 子命令不接收额外位置参数，将忽略多余参数：${extraArgs.join(' ')}');
      }
      exitCode = await _runStep(
        flutterBin: flutterBin,
        label: 'Windows Debug 构建 (build)',
        flutterArgs: _buildWindowsDebugArgs(),
        timeout: const Duration(seconds: 240),
      );
    case 'all':
      if (extraArgs.isNotEmpty) {
        stderr.writeln('错误：all 子命令不接受额外参数：${extraArgs.join(' ')}');
        _printUsage();
        exitCode = 64;
        return;
      }
      exitCode = await _runAll(flutterBin);
    default:
      stderr.writeln('错误：未知子命令 "$command"。');
      _printUsage();
      exitCode = 64;
  }
}

/// 串行执行全套交付门禁流程，任一阶段失败立即终止。
Future<int> _runAll(String flutterBin) async {
  final steps = <({String label, List<String> args, Duration timeout})>[
    (
      label: '阶段 1/3 · 静态代码分析 (analyze)',
      args: const ['analyze'],
      timeout: const Duration(seconds: 90),
    ),
    (
      label: '阶段 2/3 · 全量回归测试 (test)',
      args: const ['test'],
      timeout: const Duration(seconds: 180),
    ),
    (
      label: '阶段 3/3 · Windows Debug 构建 (build)',
      args: _buildWindowsDebugArgs(),
      timeout: const Duration(seconds: 240),
    ),
  ];

  for (final step in steps) {
    final code = await _runStep(
      flutterBin: flutterBin,
      label: step.label,
      flutterArgs: step.args,
      timeout: step.timeout,
    );
    if (code != 0) {
      return code;
    }
  }

  await _playBeep();
  stdout.writeln('✅ 全部门禁检查已通过 (analyze -> test -> build)。');
  return 0;
}

/// 执行单个门禁步骤，实时透传输出并在超时后强杀整棵子进程树。
Future<int> _runStep({
  required String flutterBin,
  required String label,
  required List<String> flutterArgs,
  required Duration timeout,
}) async {
  stdout.writeln('==> [$label] 执行：$flutterBin ${flutterArgs.join(' ')}（超时上限 ${timeout.inSeconds} 秒）');
  final stopwatch = Stopwatch()..start();

  final process = await Process.start(
    flutterBin,
    flutterArgs,
    runInShell: Platform.isWindows,
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
      '❌ [$label] 已超过 ${timeout.inSeconds} 秒超时上限，已强制清理子进程树 (PID=${process.pid})。',
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

/// 基于当前 Dart 可执行文件路径查找同级或所属 Flutter SDK 的 `flutter.bat`。
String? _resolveFlutterExecutable() {
  final targetName = Platform.isWindows ? 'flutter.bat' : 'flutter';
  var current = File(Platform.resolvedExecutable).parent;

  // 优先检查同级目录；若位于 bin/cache/dart-sdk/bin 下，则沿祖先目录查找 flutter.bat。
  for (var depth = 0; depth < 6; depth++) {
    final direct = File('${current.path}${Platform.pathSeparator}$targetName');
    if (direct.existsSync()) {
      return direct.path;
    }
    final nestedBin = File(
      '${current.path}${Platform.pathSeparator}bin${Platform.pathSeparator}$targetName',
    );
    if (nestedBin.existsSync()) {
      return nestedBin.path;
    }
    final parent = current.parent;
    if (parent.path == current.path) {
      break;
    }
    current = parent;
  }
  return null;
}

/// 在 Windows 下强制结束整棵子进程树，避免残留 cmake / dart / flutter_tester 锁死文件。
Future<void> _terminateProcessTree(Process process) async {
  if (Platform.isWindows) {
    try {
      await Process.run(
        'taskkill',
        ['/F', '/T', '/PID', '${process.pid}'],
      );
      return;
    } catch (_) {
      // taskkill 调用失败时兜底使用原生 kill。
    }
  }
  process.kill(ProcessSignal.sigkill);
}

/// 在全量门禁完成或超时熔断时触发轻量提示音。
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

/// 构造 Windows Debug 构建参数；若仓库根目录存在本地密钥定义文件则自动附带注入。
List<String> _buildWindowsDebugArgs() {
  const baseArgs = ['build', 'windows', '--debug'];
  final devDefines = File('dart_defines.dev.json');
  if (devDefines.existsSync()) {
    return [...baseArgs, '--dart-define-from-file=dart_defines.dev.json'];
  }
  return baseArgs;
}

/// 打印门禁脚本命令行用法说明。
void _printUsage() {
  stdout.writeln(
    '用法：dart run tool/verify.dart <analyze|test|build|all> [额外参数]\n'
    '  analyze                运行 flutter analyze（90 秒超时）\n'
    '  test [测试路径...]     运行 flutter test（180 秒超时）\n'
    '  build                  运行 flutter build windows --debug（240 秒超时）\n'
    '  all                    串行执行 analyze -> test -> build（完成/超时提示音）',
  );
}
