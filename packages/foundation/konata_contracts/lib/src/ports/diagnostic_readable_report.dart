import 'diagnostic_log_port.dart';

/// 面向普通用户的日志摘要；不改变机器可读事件与故障码。
abstract final class DiagnosticReadableReport {
  static String subsystemName(DiagnosticSubsystem subsystem) =>
      switch (subsystem) {
        DiagnosticSubsystem.app => '应用',
        DiagnosticSubsystem.ui => '界面',
        DiagnosticSubsystem.playback => '视频播放',
        DiagnosticSubsystem.subtitle => '字幕',
        DiagnosticSubsystem.audio => '音频播放',
        DiagnosticSubsystem.scraper => '媒体库扫描',
        DiagnosticSubsystem.source => '媒体源',
        DiagnosticSubsystem.sync => '备份与同步',
        DiagnosticSubsystem.tracker => '追踪记录',
        DiagnosticSubsystem.network => '网络',
        DiagnosticSubsystem.storage => '存储',
        DiagnosticSubsystem.window => '窗口',
      };

  static String severityName(DiagnosticSeverity severity) => switch (severity) {
    DiagnosticSeverity.debug => '详细记录',
    DiagnosticSeverity.info => '信息',
    DiagnosticSeverity.warn => '警告',
    DiagnosticSeverity.error => '错误',
    DiagnosticSeverity.fatal => '严重错误',
  };

  static String? _knownProblem(String code) => switch (code) {
    'WEBDAV_401' => 'WebDAV 登录验证失败',
    'BGM_AUTH_FAILED' => 'Bangumi 登录验证失败',
    'BGM_HTTP_ERROR' => 'Bangumi 服务请求失败',
    'BGM_TRANSPORT_ERROR' => '无法连接 Bangumi',
    'AUDIO_PLAYBACK_FAILURE' => '音频播放失败',
    'AUDIO_CUE_INITIAL_LOAD_FAIL' ||
    'AUDIO_CUE_RESUME_LOAD_FAIL' => '无法读取音频分轨信息',
    'AUDIO_AUXILIARY_LOAD_FAIL' => '部分音频附加信息加载失败',
    'AUDIO_HISTORY_UPSERT_FAIL' => '音频播放记录保存失败',
    'SCAN_GALLERY_LOAD_FAIL' => '扫描图册加载失败',
    'SCAN_THUMB_BUILD_FAIL' => '图片缩略图生成失败',
    'SCAN_PREFS_SAVE_FAIL' => '图册设置保存失败',
    'HISTORY_RESUME_NAVIGATION_FAILED' => '无法从历史记录继续播放',
    'STARTUP_NETWORK_PRELOAD_FAILED' => '启动时网络预加载失败',
    'UNCAUGHT_FLUTTER_ERROR' => '界面运行时出现异常',
    'UNCAUGHT_PLATFORM_ERROR' => '应用运行时出现异常',
    _ => null,
  };

  static String _suggestion(DiagnosticFaultSummary fault) {
    switch (fault.code) {
      case 'WEBDAV_401':
        return '检查 WebDAV 用户名和密码，再测试连接。';
      case 'BGM_AUTH_FAILED':
        return '检查 Bangumi 访问令牌是否有效，必要时重新绑定。';
      case 'BGM_TRANSPORT_ERROR':
        return '检查网络或代理后重试。';
      case 'AUDIO_PLAYBACK_FAILURE':
        return '确认音频文件可访问，再尝试播放。';
    }
    return switch (fault.subsystem) {
      DiagnosticSubsystem.source ||
      DiagnosticSubsystem.network => '检查网络、代理或媒体源是否可访问，再重试。',
      DiagnosticSubsystem.sync => '检查同步连接与设置，再重试。',
      DiagnosticSubsystem.storage => '检查存储空间及访问权限，再重试。',
      _ => '若问题重复出现，请导出日志反馈。',
    };
  }

  static String problem(DiagnosticFaultSummary fault) =>
      _knownProblem(fault.code) ??
      (fault.sampleMessage.trim().isEmpty ? '发生未分类问题' : fault.sampleMessage);

  static String formatFault(DiagnosticFaultSummary fault) =>
      '[${severityName(fault.severity)}] ${subsystemName(fault.subsystem)}：${problem(fault)}'
      '（${fault.count} 次，最近 ${fault.lastSeen.toLocal().toString().split('.').first}）'
      '\n  建议：${_suggestion(fault)}';

  static String formatEvent(DiagnosticEvent event) =>
      '${event.timestamp.toLocal().toString().split('.').first} '
      '[${severityName(event.severity)}] ${subsystemName(event.subsystem)}：'
      '${_knownProblem(event.code) ?? event.message}';

  static String overview(DiagnosticSummaryCounts counts) =>
      counts.errorCount == 0 && counts.warningCount == 0
      ? '当前日志中没有错误或警告。'
      : '本次保留的记录：${counts.errorCount} 条错误，${counts.warningCount} 条警告。';
}
