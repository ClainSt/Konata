import 'package:flutter/widgets.dart';

/// Konata v3 Windows 桌面与默认入口占位壳。
///
/// 用于 Phase 0 首日验证多包工作区、原生 CMake 链接与双端可运行骨架；
/// 底座落地后由 `bootstrap/windows_app.dart` 接管完整组装逻辑。
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const KonataBootstrapShell(platformLabel: 'Windows'));
}

/// Phase 0 最小可运行启动壳。
final class KonataBootstrapShell extends StatelessWidget {
  /// 构造带平台标识的启动占位壳。
  const KonataBootstrapShell({
    super.key,
    required this.platformLabel,
  });

  /// 当前宿主平台显示名称。
  final String platformLabel;

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: const Color(0xFF141817),
        child: Center(
          child: Text(
            'Konata v3 ($platformLabel)',
            style: const TextStyle(
              color: Color(0xFFE6ECE8),
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}
