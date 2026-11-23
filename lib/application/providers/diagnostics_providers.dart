import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../infrastructure/logging/diagnostics_log_store.dart';

const String _kVerboseLoggingKey = 'konata_v2_verbose_logging';

/// 全局诊断日志存储器 Provider。
final diagnosticsLogStoreProvider = Provider<DiagnosticsLogStore>((ref) {
  return DiagnosticsLogStore();
});

/// 诊断日志统计摘要实时流 Provider（供设置页无轮询展示已捕获异常/告警数）。
final diagnosticsSummaryCountsProvider =
    NotifierProvider<DiagnosticsSummaryNotifier, DiagnosticsSummaryCounts>(
      DiagnosticsSummaryNotifier.new,
    );

/// 诊断统计计数响应式通知器（微任务合并刷新，避免构建期内同步写状态）。
class DiagnosticsSummaryNotifier extends Notifier<DiagnosticsSummaryCounts> {
  void Function()? _unsubscribe;
  bool _syncScheduled = false;

  @override
  DiagnosticsSummaryCounts build() {
    final store = ref.watch(diagnosticsLogStoreProvider);
    _unsubscribe?.call();
    _unsubscribe = store.addListener(() {
      if (_syncScheduled || !ref.mounted) return;
      _syncScheduled = true;
      Future<void>.microtask(() {
        _syncScheduled = false;
        if (ref.mounted) {
          state = store.summaryCounts;
        }
      });
    });
    ref.onDispose(() {
      _unsubscribe?.call();
      _unsubscribe = null;
    });
    return store.summaryCounts;
  }
}

/// 详细调试日志开关管理器。
class VerboseLoggingNotifier extends Notifier<bool> {
  /// 创建调试日志开关管理器（可选传入外部日志存储器以兼容单元测试）。
  VerboseLoggingNotifier([this._injectedStore]);

  final DiagnosticsLogStore? _injectedStore;
  late DiagnosticsLogStore _store;

  @override
  bool build() {
    _store = _injectedStore ?? ref.watch(diagnosticsLogStoreProvider);
    unawaited(_restore());
    return false;
  }

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final enabled = prefs.getBool(_kVerboseLoggingKey) ?? false;
      if (!ref.mounted) return;
      state = enabled;
      _store.setVerbose(enabled);
    } catch (error) {
      developer.log(
        '恢复详细调试日志开关失败',
        name: 'konata.diagnostics_providers',
        error: error,
      );
    }
  }

  /// 设置详细调试日志开关并持久化。
  Future<void> setEnabled(bool enabled) async {
    state = enabled;
    _store.setVerbose(enabled);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kVerboseLoggingKey, enabled);
    } catch (error) {
      developer.log(
        '持久化详细调试日志开关失败',
        name: 'konata.diagnostics_providers',
        error: error,
      );
    }
  }

  /// 导出结构化诊断日志（TXT 或 JSON）到指定路径。
  Future<void> exportIncidentLog(String targetPath) {
    return _store.exportToFile(targetPath);
  }
}

/// 详细调试日志开关 Provider。
final verboseLoggingProvider = NotifierProvider<VerboseLoggingNotifier, bool>(
  VerboseLoggingNotifier.new,
);
