import 'package:konata_contracts/konata_contracts.dart';

/// 播放引擎诊断日志适配器：将标签化日志事件统一映射至 [DiagnosticLogPort]。
abstract final class PlaybackLogHelper {
  /// 记录一条结构化播放诊断日志；未注入 [logPort] 时静默跳过。
  static void record(
    DiagnosticLogPort? logPort,
    String tag,
    String message, {
    bool isError = false,
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?> context = const <String, Object?>{},
  }) {
    if (logPort == null) {
      return;
    }
    final subsystem = _mapSubsystem(tag);
    if (isError && error != null) {
      logPort.logError(
        subsystem: subsystem,
        code: tag,
        message: message,
        error: error,
        stackTrace: stackTrace,
        source: tag,
        context: context,
      );
      return;
    }
    logPort.logEvent(
      subsystem: subsystem,
      code: tag,
      message: message,
      severity: isError ? DiagnosticSeverity.error : DiagnosticSeverity.info,
      source: tag,
      context: context,
      error: error,
      stackTrace: stackTrace,
    );
  }

  static DiagnosticSubsystem _mapSubsystem(String tag) {
    final lower = tag.toLowerCase();
    if (lower.contains('audio')) {
      return DiagnosticSubsystem.audio;
    }
    if (lower.contains('sub') || lower.contains('font')) {
      return DiagnosticSubsystem.subtitle;
    }
    return DiagnosticSubsystem.playback;
  }
}
