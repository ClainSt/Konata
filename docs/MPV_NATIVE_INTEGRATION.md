# CCPlayer 原生 MPV 配置

## 当前行为

Windows 和 Android 在「设置 → 播放器 → 选择配置目录」调用系统文件选择器。选择后启用自定义配置。每次起播前仅从所选目录读取 UTF-8 编码的 `mpv.conf` 与 `input.conf`，每份最多 256 KiB。缺少其中一份时按空文件处理。应用按次生成私有副本，播放结束释放。更换目录或切回应用内配置时保留原文件。Android 使用系统文档提供方的持久只读授权。

原生 ASS 由 libass 默认渲染。WebDAV 使用播放器默认缓存恢复行为。Windows 可选增强解码引擎继续独立提供，并校验下载的归档和 DLL。自定义 MPV 配置可执行原生命令，请只选择可信文件。

## 后续可能更新

双端 Lua 脚本管理和执行支持留待后续评估。已有脚本由用户保管。

## 2026-11-06 历史验证记录

以下为当日引擎和原型的验证记录。当前支持范围见上文。

## PlayKit 兼容性／许可审查

- 参考官方项目：https://github.com/hooke007/mpv_PlayKit
- PlayKit Windows 配置目录不止 `mpv.conf` / `input.conf`：还可能有 `profiles.conf`、`input_uosc.conf`、`script-opts.conf`、多个脚本和 shader，某些功能依赖独立的 OSC、缩略图脚本、VapourSynth 和可执行组件，不应直接照搬到 Android。
- 该项目的 LICENSE.MD 明确指出多种上游许可，并说明未列出的文件不能自动视为可再分发。因此本阶段**没有直接复制整个 PlayKit 默认包或第三方脚本**到 CCPlayer。原始要求“默认与 PlayKit 一致”**仍未完全实现**；可由用户使用配置编辑、单文件导入和配置目录自行安装合法来源的文件。需要额外许可审查与兼容性评估后才能提供官方随包预设。
- 官网文档：https://github.com/hooke007/mpv_PlayKit/wiki/2_portable_config
- 许可：https://github.com/hooke007/mpv_PlayKit/blob/main/LICENSE.MD

## 验证

- `flutter analyze --no-pub`：最终结果 **0 问题**。报告 `docs/verification/mpv-final-analyze-20261106.txt`。
- `flutter test --no-pub`：最终完整回归 **265 项通过、6 项跳过、0 项失败**。报告 `docs/verification/mpv-final-regression-20261106.txt`。
- Windows 真实 native mpv 专项：默认引擎能加载 mpv.conf/input.conf；候选增强 DLL 可自动加载简单 Lua；观察到 mpv.conf 的 load-scripts 可以覆盖默认选项。
- Windows Debug 构建：最终再次通过，`build/windows/x64/runner/Debug/CCPlayer.exe`；报告 `docs/verification/mpv-final-windows-build-20261106.txt`。
- Android Debug APK：API 35 模拟器成功安装、打开设置，加载 flutter.so 与 libmpv.so，无启动致命崩溃。竖屏排版已通过模拟器截图复核。
- Android 原生集成测试：真实 NativePlayer 加载 mpv.conf 并执行 input.conf 的自定义键；Lua probe 证实当前随包 libmpv.so **不能执行 Lua**，故继续禁用 Android 执行开关。两项测试通过。日志：docs/verification/mpv-android-native-integration.txt、docs/verification/mpv-android-native-lua-capability.txt。
- Lua script-opts：为已导入脚本提供对应参数文件的内置编辑器；保留 .bak，拒绝路径穿越和超限文本。Android 窄屏文件卡片动作分行显示，实机模拟器截图已核验。
- 集成测试命令：`flutter test --no-pub integration_test/mpv_android_integration_test.dart -d emulator-5554 --reporter expanded`，需设置本机 `ANDROID_HOME`、`ANDROID_SDK_ROOT`、`JAVA_HOME`，并连接模拟器。

## 尚未验收

完整的 mpv_PlayKit 预设兼容、Android Lua 执行、Windows/Android 实际视频播放画质与字幕等价性、鼠标和完整 input.conf 行为、增强 DLL 在真实 CCPlayer 窗口中启动播放、跨设备 MPV 配置同步。
