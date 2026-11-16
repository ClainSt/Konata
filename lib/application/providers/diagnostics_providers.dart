import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../infrastructure/logging/diagnostics_log_store.dart';

const String _kVerboseLoggingKey = 'konata_v2_verbose_logging';

/// 全局诊断日志存储器 Provider。
final diagnosticsLogStoreProvider = Provider<DiagnosticsLogStore>((ref) {
  return DiagnosticsLogStore();
});

/// 详细调试日志开关管理器。
class VerboseLoggingNotifier extends StateNotifier<bool> {
  /// 创建调试日志开关管理器。
  VerboseLoggingNotifier(this._store) : super(false) {
    _restore();
  }

  final DiagnosticsLogStore _store;

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final enabled = prefs.getBool(_kVerboseLoggingKey) ?? false;
      if (!mounted) return;
      state = enabled;
      _store.setVerbose(enabled);
    } catch (_) {}
  }

  /// 设置详细调试日志开关并持久化。
  Future<void> setEnabled(bool enabled) async {
    state = enabled;
    _store.setVerbose(enabled);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kVerboseLoggingKey, enabled);
    } catch (_) {}
  }

  /// 导出最近异常日志 TXT 到指定路径。
  Future<void> exportIncidentLog(String targetPath) {
    return _store.exportToFile(targetPath);
  }
}

/// 详细调试日志开关 Provider。
final verboseLoggingProvider =
    StateNotifierProvider<VerboseLoggingNotifier, bool>((ref) {
      return VerboseLoggingNotifier(ref.watch(diagnosticsLogStoreProvider));
    });
