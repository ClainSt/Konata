# 双端本地 mpv 播放基准 · 2026-11-06

## 条件与结果

公共样片为 1920×1080 HEVC Main10 SDR、FLAC/AAC、内封 ASS 与字体的 hevc-multi-font.mkv，SHA-256 为 0640bf9cb0631353bd74ae208a9792eb3bb26b56c384fa0159442bc415a0c7a1。Android 样片先暂存到手机后打开本地文件。CCPlayer 走正式 WatchPage、隔离数据库及默认偏好。参考程序为本机 D:/mpv-lazy/mpv.com 的无配置和便携配置，以及 Android 官方 2026-09-17 arm64 版。所有测试使用 SDR，音轨选择和字幕选择记录在[参数快照](verification/local-mpv-baseline-20261106.json)。每次读取的空字符串代表该版本未给值或选项为空。短时间的掉帧计数只供定位。

| 实测路径 | 实际解码 / VO | 放大 / 缩小 | 关键观察 |
|---|---|---|---|
| Windows CCPlayer 默认 | d3d11va-copy / libmpv | bilinear / bilinear | 解码 p010；项目默认 Flutter 纹理为 BGRA8 |
| Windows CCPlayer 原生子窗 | d3d11va / gpu | bilinear / bilinear | 底层 p010，输出选项 rgb10_a2 |
| Windows 独立 mpv 无配置 | 软件 / gpu-next | lanczos / hermite | dither=fruit、dither-depth=auto，默认未选本样片 ASS |
| Windows 独立 mpv 便携配置 | d3d11va-copy / gpu-next | bilinear / bicubic | dither=fruit、dither-depth=no，已选 ASS |
| Android 2407FRK8EC，CCPlayer | mediacodec-copy / gpu | bilinear / bilinear | Main10 解码输出 yuv420p，BT.709、BT.1886、limited |
| 同手机官方 mpv-android | mediacodec / gpu | 官方运行日志未披露 | 同样的源尺寸、色彩标记及 FLAC；输出为不透明硬件表面，实际显示位深待测 |

## Windows 实际动画同帧

使用本地《86》第一集 Main10 SDR，在 123.957 秒暂停。正式播放页的 D3D11 子窗口与独立 mpv 均为 2534×1369，关闭字幕和 OSD。CCPlayer 从正在播放的 libmpv 会话直接执行 screenshot-raw window，读取 BGR0（每行含填充）；独立 mpv 执行 screenshot-to-file window 生成 8 位 PNG。比较时剔除行填充和第 4 通道，保留完整窗口。独立无配置组、便携组分别保留各自渲染设置，对齐组显式选择 gpu、D3D11、d3d11va、rgb10_a2、bilinear 放缩、dither=no，并关闭 correct-downscaling、linear-downscaling、sigmoid-upscaling、hdr-compute-peak。内核版本仍分别为 0.36 开发版与 0.41 开发版。

| 原生子窗对比独立 mpv | RGB 平均绝对差（0–255） | 差值超过 2 的通道比例 | 最大差值 |
|---|---:|---:|---:|
| 对齐参数 | 0 | 0% | 0 |
| 无配置 | 0.8483 | 8.2618% | 27 |
| 便携配置 | 3.7967 | 14.8576% | 255 |

三个数值是与参考画面之间的距离，不能作为优劣评分。完全一致限定于这一帧、这一尺寸和渲染器提供的八位窗口回读。未比较面板最终输出、HDR、10 位最低有效位、复杂字幕特效或整集能耗。默认 Flutter 纹理组记录了播放参数，本轮未对 Flutter 合成后的实屏像素做同帧差分。

## 复测入口和决策

运行 integration_test/local_mpv_baseline_test.dart，用 BASELINE_VIDEO 传样片本地路径。Android 可以用 BASELINE_STAGE_URL 从项目已有的 loopback 样片服务预先复制一个文件，再从测试私有目录播放；使用 CCPLAYER_ISOLATED_VALIDATION=1。Windows 增加 CCPLAYER_NATIVE_SDR_OUTPUT=true 可检查原生子窗。另指定全新 BASELINE_WINDOW_BGR0 绝对路径和 BASELINE_FRAME_SECONDS 可做精确寻址后窗口回读，终端会给出宽、高及 stride。独立 mpv 要分别测试 --no-config 和实际便携设置，比较像素时固定相同窗口尺寸、时间、轨道可见性和输出模式。

本轮保留两端发布默认值。现有 Windows 原生路径能复现对齐的独立 mpv 参考帧；把所有用户的缩放改成 Lanczos 并不能复现本机便携配置。默认纹理与原生路径的实屏渐变、全屏交互及功耗尚应分别对照。Android 优先用同一真机做 direct/copy/软件解码三组，并验证 Surface 重建、字幕、颜色和持续播放。仅凭直接硬解的不透明格式，无法判断其实际输出位深。此次没有改动产品依赖或构建发布包。
