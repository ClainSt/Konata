/// 用户可见发布版本；与应用 pubspec 的版本名称保持一致。
/// V3 分支和诊断/备份格式版本不代表发布版本。
abstract final class KonataAppVersion {
  /// 只有正式决定升级版本时才修改。
  static const release = '1.0.0';
}
