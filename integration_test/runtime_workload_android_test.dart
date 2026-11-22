import 'package:konata/main_android.dart' as android_app;

import 'runtime_workload_body.dart';

/// Android 真机专用主干页面实机基准入口（仅导入 `main_android.dart`，编译期彻底裁剪桌面组装根）。
void main() {
  runRuntimeWorkloadBenchmark(launchApp: android_app.main);
}
