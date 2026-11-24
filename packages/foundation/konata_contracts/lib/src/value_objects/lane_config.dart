/// Konata 编译期车道标识与同机多版本隔离配置（纯 Dart 零外部依赖）。
///
/// 通过 `--dart-define=KONATA_LANE=<lane>` 在编译期指定运行车道：
/// - 缺省空值或 `main`：主干正式车道，完整保留正式窗口标题与便携根目录；
/// - 其它合法标识（如 `next`、`maint`）：自动启用同机存储分流至 `Konata_<lane>` 与标题徽标隔离。
abstract final class KonataLaneConfig {
  /// 编译期注入的原始车道参数（由 `--dart-define=KONATA_LANE=...` 传入）。
  static const String rawCompileTimeLane = String.fromEnvironment(
    'KONATA_LANE',
    defaultValue: '',
  );

  /// 正式主干车道的保留标识字面量。
  static const String mainLaneName = 'main';

  /// 应用基础展示标题。
  static const String defaultAppTitle = 'Konata';

  /// 隔离车道数据目录命名前缀。
  static const String isolatedDirPrefix = 'Konata_';

  static final RegExp _validLanePattern = RegExp(r'^[a-z][a-z0-9_]{0,31}$');

  /// 解析规范化后的隔离车道名；主干环境（空值或 `main`）返回空字符串。
  static String resolveLane([String? rawOverride]) {
    final normalized = (rawOverride ?? rawCompileTimeLane).trim().toLowerCase();
    if (normalized.isEmpty || normalized == mainLaneName) {
      return '';
    }
    if (!_validLanePattern.hasMatch(normalized)) {
      throw ArgumentError.value(
        rawOverride ?? rawCompileTimeLane,
        'KONATA_LANE',
        '车道标识仅允许字母开头的字母、数字与下划线（长度不超过 32 位）',
      );
    }
    return normalized;
  }

  /// 当前是否运行在非主干的独立隔离车道。
  static bool isIsolatedLane([String? rawOverride]) =>
      resolveLane(rawOverride).isNotEmpty;

  /// 返回隔离车道专属数据子目录名（如 `Konata_next`）；主干环境返回空。
  static String? isolatedDirectoryName([String? rawOverride]) {
    final lane = resolveLane(rawOverride);
    if (lane.isEmpty) {
      return null;
    }
    return '$isolatedDirPrefix$lane';
  }

  /// 生成桌面端窗口与任务栏显示标题；主干保持 `Konata`，隔离车道追加 `[<LANE>]`。
  static String resolveDesktopWindowTitle({
    String baseTitle = defaultAppTitle,
    String? rawOverride,
  }) {
    final lane = resolveLane(rawOverride);
    if (lane.isEmpty) {
      return baseTitle;
    }
    return '$baseTitle [${lane.toUpperCase()}]';
  }

  /// 生成 Android 启动器应用名；主干保持 `Konata`，隔离车道追加 `(<LANE>)`。
  static String resolveAndroidLauncherLabel({
    String baseLabel = defaultAppTitle,
    String? rawOverride,
  }) {
    final lane = resolveLane(rawOverride);
    if (lane.isEmpty) {
      return baseLabel;
    }
    return '$baseLabel (${lane.toUpperCase()})';
  }
}
