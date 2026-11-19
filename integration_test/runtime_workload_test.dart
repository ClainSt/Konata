import 'dart:io';

import 'package:ccplayer/main.dart' as desktop_app;
import 'package:ccplayer/main_android.dart' as android_app;
import 'package:ccplayer/presentation/shell/top_nav_bar.dart';
import 'package:flutter_test/flutter_test.dart';

import 'runtime_workload_body.dart';

/// 跨端实机负载基准总入口：按目标平台精确分流至 `AndroidCompositionRoot` 或 `WindowsCompositionRoot`。
void main() {
  if (Platform.isAndroid) {
    runRuntimeWorkloadBenchmark(launchApp: android_app.main);
    return;
  }
  runRuntimeWorkloadBenchmark(
    launchApp: desktop_app.main,
    desktopNavFinder: (label) => find
        .descendant(of: find.byType(TopNavBar), matching: find.text(label))
        .hitTestable(),
  );
}
