# BDRIP-FIX-REPORT

日期：2026-11-06。阶段性交付，未完成全部格式/全部设备/全部十分钟用例。

## 已修复与验证

### Windows 增强库首次出画面崩溃

实际复现：Dart通过绝对路径加载增强DLL，Windows视频插件仍通过链接默认DLL调用mpv；首次H264软解即0xc0000005，事件记录故障模块为默认旧DLL。修复：Dart发送已选NativeLibrary.path，Windows每个VideoOutput通过GetModuleHandleW/GetProcAddress绑定同一模块的七个MPV函数；异步释放捕获该模块对应的free函数。未覆盖默认DLL、未修改ANGLE/纹理精度。修复后增强原五样片14项通过，默认扩展七样片18项通过；增强扩展七样片18项也已通过。

文件：packages/media_kit_video/windows/video_output.h、video_output.cc、media_kit_video_plugin.cc；lib/src/video_controller/native_video_controller/real.dart；CCPLAYER_PATCH.md。

### 解码模式与用户配置优先级

lib/core/mpv_config_store.dart、lib/ui/mpv_settings_panel.dart提供默认、优先硬解、软件、自定义模式。默认路径保留；软件只关闭解码硬件加速，不关闭GPU渲染。Android模拟器始终软件解码。自定义读取初始化配置hwdec，避免等待自身初始化造成死锁。显式失败/未生效回退no并读回；MPV接受未知后端字符串时由其运行时回退，测试已验证，不能宣称读回即可判断后端可用。

packages/media_kit/lib/src/player/platform_player.dart、native/player/real.dart增加显式mpvRespectRenderingConfiguration；开启自定义模式时不再覆盖四个已接入渲染选项。它不是“所有配置永远优先”：vo、surface、运行期脚本/配置等仍由已有链路控制。用户mpv.conf和Lua文件未改写。

相关：packages/media_kit_video/lib/src/utils/decode_policy.dart、Android/Native controller；lib/ui/watch_page.dart接入设置并为隔离正式页测试提供configurationStore注入；lib/l10n ARB及生成文本；test/video_decode_mode_test.dart、mpv_settings_panel_test.dart、mpv_render_config_native_test.dart。

### 字幕与诊断

Windows原生libass增加默认关闭的可选项，下次播放生效；保持原默认字幕渲染不变。真实截图验证外挂中文ASS可绘制；复杂动画字幕、所有字体/特效并未全覆盖。Android原生ASS与内封Noto字体专项2项（含清单）已通过并检查截图；产品开关仍关闭，字体回退与复杂特效待补。

lib/core/playback_probe.dart识别mpv返回的yuv420p10/p010别名，统计区分实际解码像素格式与Flutter纹理；不据此保证最终显示10-bit。

### 验证工具

- integration_test/playback_compatibility_test.dart：原生Video纹理、软解/自动模式、截图、暂停跳转、自定义配置回退、本地Range代理。Android修正测试pump时序，等待真实video-params，保留首轮失败日志。
- integration_test/bdrip_watch_page_test.dart：正式WatchPage+临时Catalog/内存设置，循环/暂停/跳转、内存和MPV采样、进度落盘与释放。
- test/native_codec_inventory_test.dart、integration_test/native_codec_inventory_test.dart：原生库解码器/编译参数；test/bdrip_audio_native_test.dart：TrueHD缺失与AAC显式恢复、增强TrueHD实际解码。音频输出null，不作为声学验收。
- tool/generate_playback_fixtures.ps1、extend_playback_fixtures.ps1、serve_playback_fixtures.cjs、stage_android_playback_fixtures.ps1、prepare_bdrip_engine.dart：仅自制样片/回环传输/隔离引擎；不向云盘或用户媒体写入。
- android/app/build.gradle.kts：显式CCPLAYER_ISOLATED_VALIDATION=1时Debug包名后缀.validation；常规构建不变。

## 数据与安全事件

无数据库迁移；本轮未修改身份/同步数据库架构。正式页测试数据库位于临时目录，设置为内存模拟。没有读取光鸭云盘、写入Bangumi、修改用户视频、用户mpv.conf或Lua。

**发生真实设备安装影响**：首次真机独立包安装被系统拒绝，Flutter集成测试清理疑似使用旧APK包信息卸载了正式com.clainst.ccplayer；前后安装列表显示正式包消失。已立即告知用户、停止真机写入并询问数据情况。用户明确确认没有需要保留的数据，随后要求重新发送安装。独立包在用户允许USB安装后成功安装，后续一律--no-uninstall。无法证明原私有数据仍可恢复，不宣称“未涉及真实用户数据”。不得再依赖构建时环境后缀保护有数据设备；须先构建并核实APK及Flutter识别包名，关闭卸载。

## 已确认未修复 / 未验收

- 默认Windows真实库缺TrueHD；自制样片实际报解码初始化失败。AAC备用轨显式恢复已验证；尚未新增自动过滤不支持轨道，不自动替换默认库。
- 真机auto-safe/mediacodec-copy对Main10报告8-bit解码输出；色带/高位深显示精度尚未验收。保留安全路径，不以强制硬解代替修复。
- AV1/Opus、MPEG2/VC1隔行、DTS-HD MA、422/444/12bit、HDR10+/DolbyVision、bitstream缺样片或设备，未测试。
- 全部样片逐一双端本地/模拟WebDAV和逐一十分钟未完成；目前本地Range只用H264样片，十分钟只覆盖4K Main10循环，不等价于真实长片或高码率云盘。
- Android复杂ASS/内封字体、AAC备用轨切换、主观音质/声道映射、HDR校准均需后续验证。
- 模拟器首轮失败已记录；修正时序仍超时，软件图形后端对照也失败，扩展矩阵中断。真机不能替代模拟器结果，模拟器更不能替代硬件结果。

最终测试/构建结果以文末追加验收记录为准；早期历史基线不是本轮结果。

## 最终验收记录

- 静态分析：0问题（bdrip-final-analyze-20261106.txt）。
- 全量单元/组件：299通过、10跳过、0失败（bdrip-final-regression-20261106.txt）；跳过包括须显式原生库/设备的测试，未伪装通过。
- 默认Windows：18项集成播放通过；增强Windows：18项通过；各自真实TrueHD/AAC原生专项1项通过（默认用例验证真实失败和显式恢复）。
- Windows正式WatchPage：601秒、120采样通过。真机首轮播放17通过/1跳过，后续清单与内封ASS/字体2通过；真机正式WatchPage：601秒、119采样通过。
- 模拟器软件图形后端最小H264对照仍失败，未完成验收。
- Windows Debug正常入口构建通过；Android Debug正常入口APK构建通过、真机正常包安装和启动成功；未做Release构建。
- git diff --check成功（只有既有文件换行提示）；未提交、未清理未知文件。

下一步先补Android原生字幕的系统字体回退/设置接入及Main10安全copy输出位深诊断，再处理默认库TrueHD能力与自动备用音轨；用合法样片补AV1、隔行、DTS-HD和更多ASS，不先引入大型依赖或强制渲染更换。

- 扩展样片复现工具已在全新.dart_tool/bdrip-extension-repro执行成功，生成AAC、双音轨/字体附件、TrueHD/AAC三个容器；基础视频码流复制，未读取用户视频。正常Android进程启动后仍存活。已撤销两端测试端口转发并停止本机样片服务。
