import 'package:konata/main_android.dart' as android_app;

import 'full_stress_suite_body.dart';

/// Android 手机与平板专用的全页面实机压力测试入口（零桌面依赖，含横竖屏旋转与触控导航压测）。
void main() {
  runFullAppRealDeviceStressSuite(
    launchApp: android_app.main,
    platformTag: 'android_device',
    runAndroidOrientationStress: true,
  );
}
