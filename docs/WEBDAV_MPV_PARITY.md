# WebDAV 原码流与独立 mpv 播放一致性

2026-11-06。**同一个 BDRip 经 CCPlayer 的 WebDAV 播放路径可以保留文件内的视频、音频、字幕和字体附件。** 客户端转发上游文件字节，所选轨道仍由 libmpv 解码。最终画面还取决于两端的解码格式、缩放、字幕配置及显示链路。Windows 默认视频纹理每色通道 8 位；已有 Android 真机记录中，一份 Main10 样片在默认硬解路径也报告了 8 位解码输出。现有证据支持原码流传输设计，尚不足以宣称两端画面与独立 mpv 完全一致。

## WebDAV 与本地播放的分界

播放页给本地文件传入路径，给远端文件签发回环 HTTP 地址，最终都调用同一个播放器的 `open(Media(uri))`。预览使用单独的票据。中继请求 identity 编码、关闭自动解压，转发 Range 和 If-Range，校验 206 的区间与长度，对不满足所请求区间的整文件响应报错。收到有效响应后直接传递字节，路径中没有转码、码率档位选择或图像处理。因此链路变慢首先应检查缓冲、拖动和首帧延迟；若画面持续模糊或渐变出现色带，应核对服务端返回的文件、解码和输出路径。[播放入口](../lib/ui/watch_page.dart) · [媒体票据](../lib/core/sources.dart) · [中继实现](../lib/core/webdav_stream.dart)

原码流的前提是服务端返回同一版本的文件。使用一份不可变样本，比较原本地文件、上游下载文件以及通过中继读到的整文件长度和 SHA-256，可验证该次完整读取。若成本太高，可先抽查文件头、中段、尾部相同偏移的范围及哈希，另记录响应码、Content-Range、总长度和强 ETag（如有）；抽查结论只覆盖已比对区段。MKV 内封轨道及附件在文件哈希相同时一并得到覆盖。外挂字幕是另一个资源，须另比轨道选择、语言、字幕文件与字体。

本仓默认传给 mpv 的 demuxer 前向和后向字节上限各为 32 MiB；后向上限用于已读数据，不能加到前向缓冲预算。以稳定 80 Mbit/s 粗算，32 MiB 对应约 3.36 秒压缩数据，实际可播放时长随码率峰值、预读与缓存策略变化。播放器网络超时设置为 5 秒，中继等待上游响应头的默认值为 15 秒，接收正文的空闲上限为 30 秒。它们作用于不同层，排查卡顿应同时记录两层的错误和耗时。[播放器配置](../packages/media_kit/lib/src/player/platform_player.dart) · [mpv 初始化选项](../packages/media_kit/lib/src/player/native/player/real.dart) · [WebDAV 中继](../lib/core/webdav_stream.dart)

## 两端的实际显示路径

| 路径 | 源码及已有观测 | 能确认的边界 |
| --- | --- | --- |
| Windows 默认嵌入 | libmpv OpenGL Render API 向宿主 FBO 渲染，ANGLE 的 D3D11 共享纹理为 B8G8R8A8_UNORM，Flutter 注册为 BGRA8888。软件渲染另走 rgb0。 | 即使解码报告 P010，默认共享纹理仍只有每色通道 8 位。抖动可能改善主观渐变；无法由此证实端到端 10 位或 HDR 直通。[共享纹理](../packages/media_kit_video/windows/angle_surface_manager.cc) · [宿主渲染](../packages/media_kit_video/windows/video_output.cc) · [mpv FBO 接口](https://github.com/mpv-player/mpv/blob/master/include/mpv/render_gl.h) |
| Windows 可选验证构建 | 编译开关 CCPLAYER_NATIVE_SDR_OUTPUT 创建同一 Flutter 顶层窗口内的子 HWND，设置 wid、vo=gpu、D3D11 和 rgb10_a2。 | 绕开上述 BGRA8 纹理，提供测试高位深 SDR 的候选路径。读取选项成功仅证实接受请求，仍需抓取实际交换链格式并核实系统输出模式。mpv 当前手册的 HDR 色彩空间提示要求受支持的驱动与 gpu-next，因此此验证开关不能作为 HDR 直通证明。[原生窗口](../windows/runner/flutter_window.cpp) · [播放选项](../lib/ui/watch_page.dart) · [mpv 色彩空间说明](https://mpv.io/manual/stable/#options-target-colorspace-hint) |
| Android 默认嵌入 | media_kit_video 将 SurfaceProducer 提供的 Surface 交给 mpv，默认使用 vo=gpu、Android GPU context 和 OpenGL ES，真机默认请求 auto-safe。项目记录中一台真机播放 4K Main10，mediacodec-copy 报告 yuv420p 8 位。 | 设备、驱动、解码模式及最终 Surface 分开记录。对同一片源比较自动和软件解码，确认精度、丢帧与温升，再判断是否适合改变默认策略。[Android 控制器](../packages/media_kit_video/lib/src/video_controller/android_video_controller/real.dart) · [Surface 创建](../packages/media_kit_video/android/src/main/java/com/alexmercerind/media_kit_video/VideoOutput.java) · [实机记录](BDRIP-FIX-REPORT.md) |

对 HDR 片源，分别验证 HDR 屏显示及 SDR 屏色调映射。固定显示模式、色彩空间、黑白电平、峰值亮度和 ICC 设置。高位深 SDR 与 HDR 是两个独立的验收项。mpv Render API 将渲染目标交给宿主；mpv 处理后还有系统合成、驱动和显示设备。应结合实际交换链/Surface 与显示状态验证，单张普通截图只能核对截取点的内容。[mpv Render API](https://github.com/mpv-player/mpv/blob/master/include/mpv/render.h) · [mpv 显示与色彩空间](https://mpv.io/manual/stable/#options-target-colorspace-hint)

## 字幕、字体与播放流畅性

CCPlayer 在两端默认启用原生 libass，并允许分别关闭。Android 在适用时设置字幕备用字体。mpv 默认使用 MKV 附件字体，最终选择还依赖字幕声明的字体族、缺字回退及用户配置。验证时选择同一字幕轨，在含定位、旋转、描边、卡拉 OK 和罕见汉字的指定时间戳比较。若差异只在文字，先检查字体匹配日志、原生 ASS 开关与样式覆盖。[CCPlayer 设置](../lib/core/mpv_config_store.dart) · [Android 字体处理](../lib/core/subtitle_system_fonts.dart) · [mpv 内嵌字体](https://mpv.io/manual/stable/#options-embeddedfonts)

仓库已有正式播放页的合成 4K Main10 SDR 样片循环记录：Windows 601 秒、120 次采样，Android 真机 601 秒、119 次采样。这是该样片上持续播放和资源释放的证据。真实 NAS 的抖动、整集字幕效果、屏幕最终位深与 HDR 仍须各自验证。[原始验收索引](BDRIP-PLAYBACK-VALIDATION.md) · [编码与输出矩阵](BDRIP-CODEC-MATRIX.md)

## 可复现的四组对照

每个平台各自使用同一设备、同一显示器或屏幕、同一不可变文件。比较 **CCPlayer 本地、CCPlayer WebDAV、独立 mpv 本地、独立 mpv 直读同一 WebDAV 文件**。Android 使用独立 mpv-android。记录版本和构建、窗口尺寸与缩放、相同轨道和时间点，以及实际生效的硬解、解码像素格式、VO、缩放、抖动、去色带和色调映射选项。两份 mpv 版本或默认预设有差异时，先保留默认结果，再在可匹配设置下重复测试。[mpv 手册](https://mpv.io/manual/stable/) · [mpv-android](https://github.com/mpv-android/mpv-android)

- **画面与字幕**：固定帧在相同取样环节比较，记录线条、渐变、暗部、色彩、字体及排版。记录实际色彩输出；另看实屏 HDR 高光。分开测 H.264、Hi10P、HEVC Main10 SDR 与真正标记为 HDR 的片源。
- **播放与网络**：首次出画、指定时间跳转恢复、连续播放缓冲次数与总时长、掉帧及音画同步分别记录。冷缓存与热缓存分组，固定网络条件，用含峰值码率段落的真实素材。记录 WebDAV 错误时剔除认证头和媒体票据。
- **定位差异**：同一播放器的本地/远程差异先查字节、缓存及外部资源；两款播放器本地就有差异，先查构建和呈现链路。仅 CCPlayer 远程复现时，再针对中继的 Range、超时和预览并发做复测。
