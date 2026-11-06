# CCPlayer 可嵌入播放内核选型

2026-11-06。Windows 和 Android 均建议沿用已接入的 **libmpv**。Windows 的优先工作是验证实际显示链路的位深、色彩和缩放；Android 则是按设备验证硬解、软解回退、字幕及前后台恢复。**LibVLC** 是两端可接入的备选，**Media3 ExoPlayer** 是仅适用于 Android 的备选。三者都能在应用内播放，无需用户安装外部播放器。

## 接入起点

项目在 `pubspec.yaml` 引入 media_kit、media_kit_video 和原生播放库，并覆写前两者为本地维护版本。`lib/main.dart` 初始化 libmpv，`lib/ui/watch_page.dart` 创建 VideoController。`lib/core/mpv_config_store.dart`、轨道选择和时间轴预览也使用现有接口。进一步优化 libmpv 可复用这条路径。替换内核则需要验证视频表面与 Flutter 控件叠加、轨道事件、预览取帧和释放时序。

| 可嵌入内核 | Windows 接入 | Android 接入 | 动画 BDRip 的取舍 |
| --- | --- | --- | --- |
| **libmpv** | 继续用现有 media_kit，保留原生库和单窗口播放页。比较独立 mpv 和 CCPlayer 在同一显示器上的最终画面，定位嵌入路径差异。 | 复用同一库和播放控制，单独调试视频输出与硬解选择。mpv-android 已展示 libass、软硬解、双字幕及缩放功能。 | 与项目已有 MPV 配置和字幕处理最吻合。可调色度缩放、抖动、色调映射；内核支持的选项仍需在当前构建及输出后端验证。[libmpv 嵌入示例](https://github.com/mpv-player/mpv-examples/tree/master/libmpv) · [mpv 手册](https://mpv.io/manual/stable/) · [Android 参考实现](https://github.com/mpv-android/mpv-android) |
| **LibVLC** | 原生插件调用 C 播放 API，对接宿主窗口或渲染表面，向 Dart 转发状态和控制命令。 | 使用 LibVLC Android 绑定，对接视频表面与 Activity 生命周期。 | VLC Android 已覆盖 MKV、FLAC/AAC、多音轨、字幕和网络流。若 libmpv 在特定设备有可复现故障，可先用同一素材验证 LibVLC 是否解决，再评估移植。两端仍需逐项验证复杂 ASS、内嵌字体、颜色和 WebDAV 拖动。[原生播放 API](https://github.com/videolan/vlc/blob/master/include/vlc/libvlc_media_player.h) · [Android 绑定及构建说明](https://github.com/videolan/vlc-android#libvlc) · [功能说明](https://play.google.com/store/apps/details?id=org.videolan.vlc) |
| **AndroidX Media3 ExoPlayer** | Windows 需保留独立后端。 | 添加 Gradle 模块，在原生侧创建 ExoPlayer、绑定视频表面，通过 Flutter 平台接口控制播放并处理释放。 | 平台解码能力随设备而异。其 SSA 解析器生成字幕 Cue，后续应逐帧比较复杂特效、定位和字体；Hi10P 也需要单独验证回退路径。适合在系统集成或设备解码出现具体需求时做原型。[GitHub](https://github.com/androidx/media) · [官方接入](https://developer.android.com/media/media3/exoplayer/hello-world) · [格式支持](https://developer.android.com/media/media3/exoplayer/supported-formats) · [SSA 解析源码](https://github.com/androidx/media/blob/release/libraries/extractor/src/main/java/androidx/media3/extractor/text/ssa/SsaParser.java) |

## 采用情况与稳定性证据

- mpv 核心仓库约 3.78 万星。采用 libmpv 的 mpv-android 在 Google Play 英文页首约 4.2 分、4,400 条评价、50 万次以上下载。其更新说明列出硬解及首次 TLS 连接修复，这两类场景值得在 CCPlayer 复测。[mpv 仓库](https://github.com/mpv-player/mpv) · [mpv-android 商店页](https://play.google.com/store/apps/details?id=is.xyz.mpv)
- 采用 LibVLC 的官方 VLC Android 移植版在同一商店约 4.0 分、200 万条评价、5 亿次以上下载。其受众覆盖面更广，缺陷反馈由 VideoLAN GitLab 跟踪。[官方仓库](https://github.com/videolan/vlc-android) · [VLC 商店页](https://play.google.com/store/apps/details?id=org.videolan.vlc)
- Media3 是 AndroidX 发布的开发库，可从 Google Maven 按模块使用，有公开版本记录。上述商店数字仅衡量成品的累计下载与整体评价，随地区、设备和时间变化。公开资料没有提供三套内核在相同设备、同一动画样本上的崩溃率、帧时间或功耗，无法据此排出稳定性名次。[Media3 官方接入文档](https://developer.android.com/media/media3/exoplayer/hello-world) · [版本记录](https://github.com/androidx/media/releases)

## 画质验收与接入成本

1. **Windows** 固定同一台显示器及缩放比例，对照 SDR 线条、暗部色带、HDR 转 SDR 的高光层次，并在 HDR 屏验证实际输出以及窗口和全屏切换。分别记录源文件位深、解码格式、交换链格式及显示模式；截图只适合核对帧内容。[mpv 视频输出选项](https://mpv.io/manual/stable/)
2. **Android** 在同一真机、固定亮度与相同片段下测 H.264、Hi10P 和 HEVC Main10，记录实际解码器、掉帧、温升、耗电，以及旋转与前后台恢复情况。两端都应检查带附件字体的 ASS、FLAC/AAC 切轨同步和 WebDAV 首次出画、远距离拖动。
3. **成本与回退** 继续用现有 libmpv 可避免引入第二套运行库。LibVLC 并存会增加原生构件、发布维护和回归组合；Media3 需要维护独立 Android 控制路径及两套配置语义。若做替换原型，应在独立构建分别测 Windows ZIP、解压占用、单 ABI APK、安装占用、缓存峰值与运行资源，保留现有 libmpv 构建作回退。本次为源码与资料调研，没有改动依赖或实测性能。
