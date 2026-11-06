# 播放回归与运行时测量

2026-11-06。正式包用于安装、启动及空闲观测；解码、纹理、跳转及字幕用相同本地播放器代码、真实 libmpv、独立 Debug 测试程序和合成 MKV 验证。设备为 Windows x64 及 2407FRK8EC ARM64。测试媒体位于 .dart_tool，未列入发布资源。

## 基础矩阵

两端各通过 18 项。覆盖 H.264 8-bit、Hi10P、HEVC Main10（1080p/4K）、HDR10 元数据、FLAC/AAC、真实 Flutter 视频纹理、截图、跳转、自定义渲染配置、字幕和经过生产代理的 HTTP Range。Windows Range 记录含 bytes=0-、bytes=7222748- 和 bytes=790-；Android 记录非零跳转。外部 NAS、实际云端限流与 SMB 长期播放没有在本轮重测。

## 播放与释放后的进程 RSS

下表取同轮各片段，单位 MiB（1,048,576 字节）。播放列含已暂停的真实播放器和测试截图；释放列在 dispose 及移除 Video 后立刻读取，仍含 Flutter、测试框架和分配器保留内存。auto 列依据实际后端命名。

| 平台 | 样片 | 请求 / 实际 | 播放 | 释放后 |
|---|---|---|---:|---:|
| Windows | h264-8-1080.mkv | no / no | 557.2 | 413.8 |
| Windows | h264-8-1080.mkv | auto / d3d11va-copy | 484.6 | 454.3 |
| Windows | hevc-main10-4k.mkv | no / no | 1323.1 | 586.7 |
| Windows | hevc-main10-4k.mkv | auto / d3d11va-copy | 825.2 | 702.6 |
| Android | h264-8-1080.mkv | no / no | 617.2 | 544.0 |
| Android | h264-8-1080.mkv | auto / mediacodec | 565.9 | 557.2 |
| Android | hevc-main10-4k.mkv | no / no | 1385.4 | 852.2 |
| Android | hevc-main10-4k.mkv | auto / mediacodec | 618.0 | 602.7 |

## 短时处理器负载

Android 读取同一测试进程 /proc/self/stat 的用户与系统 CPU ticks；设备 CLK_TCK=100。每项在播放推进后采样约 1.2 秒，100% 为一个逻辑核心，包含 Flutter 进程，不含独立系统解码服务。

| 样片 | 策略 | CPU（单核口径） |
|---|---|---:|
| h264-8-1080.mkv | no | 25.7% |
| h264-8-1080.mkv | auto | 17.5% |
| h264-hi10-1080.mkv | no | 69.8% |
| h264-hi10-1080.mkv | auto | 49.8% |
| hevc-main10-4k.mkv | no | 217.1% |
| hevc-main10-4k.mkv | auto | 57.2% |

Windows 读取测试进程累计 CPU 时间、工作集和 GPU Engine 各引擎计数器。短矩阵中还包括初始化、截图、seek 及释放，无法把整段数值解释为稳定播放功耗。单进程最忙 GPU 引擎瞬时 0–37%。Android 的 Mali 频率节点拒绝读取，未取得可信 GPU 利用率或硬解服务功耗。

## 质量边界

SDR 已验输入位深及 BT.709 元数据、尺寸与截图。没有参考显示器、色度计或经过校准的参考帧对照，不能证明准确还原 SDR 或 HDR。HDR 片是携带 PQ/BT.2020 标记的合成图案。过往 Android copy 输出 8-bit 的风险保留；没有为了更小体积移除解码器，也没有将硬解请求等同于硬解成功。默认 Windows TrueHD 能力有限，原生测试显式切换 AAC 成功。

此前正式页 10 分钟长测见 docs/BDRIP-PLAYBACK-VALIDATION.md，本轮的播放/释放观测不足以证明长时间无泄漏。模拟器之前存在 EGL 输出失败，本轮以真机为主要 Android 证据。

## 扩展复核与复现

- Windows 和 ARM64 真机追加 AV1 8-bit/AAC、H.264/PCM 5.1 的软解和自动解码，共各 22 项通过（含原有 18 项）。六声道 PCM 读到了原生音轨参数；扬声器声道映射、直通与听感未测。Windows AV1 识别为 libdav1d。
- 多层 ASS 补测三项通过。使用带淡入淡出、移动、缩放、描边和阴影的第二组样片；检查了 Windows、真机 MKV 带 OTF 附件、真机外部 ASS 缺失微软雅黑的三张原生截图。上方黄字「日本語 English」与底部白字简繁字幕均可辨识，位置、描边与两种样式可区分。Android 日志确认缺失字体时选中 NotoSansCJKSC-Regular。本机原生初始化的 sub-fonts-dir 默认为空。截图仅验证抽样时刻，不能证明每一帧逐像素等同参考渲染器。
- Windows 整轮 33 个进程采样的 CPU 为 40.5–548.8%（100% 为单个逻辑核）。测试包含抓帧，未将该范围作为持续软硬解性能对比。Android 稳态 GPU 及功耗、真实平板外观、真实 NAS 与泄漏长测仍待验证。
- 全量单元及组件测试最终 309 通过、4 跳过；静态检查无问题。先前并发较高的一轮观看状态界面测试短暂超时，单独与全量复跑均通过。详情页覆盖 390×850、850×390、600×750、1024×700、1350×860（逻辑像素），包含同一页面调整尺寸和播放版本选择。
- 复现扩展矩阵可在开发机用已有合成 h264-8-1080.mkv 复制视频流、以 pcm_s16le 和 -ac 6 编码音轨生成 h264-pcm51.mkv；再将合成 h264-aac.mkv 以 libsvtav1、yuv420p 编码视频并复制音轨生成 av1-aac.mkv。运行 integration_test/playback_compatibility_test.dart 时附加 --dart-define=PLAYBACK_EXTENDED=true。Android 仅用独立 .validation 包和 USB 回环样片服务。生成器已修正旧淡入淡出标签并加入第二层字幕。原始测量日志位于 .dart_tool/size-audit-*；旧见证资料位于 docs/verification。
