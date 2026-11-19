import 'package:ccplayer/main.dart' as desktop_app;
import 'package:ccplayer/presentation/shell/top_nav_bar.dart';
import 'package:flutter_test/flutter_test.dart';

import 'runtime_workload_body.dart';

/// Windows 桌面端实机负载基准入口（注入 `WindowsCompositionRoot` 与桌面顶栏查找器）。
void main() {
  runRuntimeWorkloadBenchmark(
    launchApp: desktop_app.main,
    desktopNavFinder: (label) => find
        .descendant(of: find.byType(TopNavBar), matching: find.text(label))
        .hitTestable(),
  );
}
