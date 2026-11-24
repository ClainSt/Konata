import 'package:flutter_test/flutter_test.dart';
import 'package:konata/main.dart';

void main() {
  testWidgets('Phase 0 启动占位壳可正常挂载渲染', (tester) async {
    await tester.pumpWidget(
      const KonataBootstrapShell(platformLabel: 'Windows'),
    );

    expect(find.text('Konata v3 (Windows)'), findsOneWidget);
  });
}
