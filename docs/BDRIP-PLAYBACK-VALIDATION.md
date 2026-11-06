# BDRIP-PLAYBACK-VALIDATION

日期：2026-11-06。所有视频来自lavfi自制图案和正弦音，不读取真实媒体库或光鸭云盘；均为4秒、24fps，不能代表真实BDRip码率和字幕复杂度。

## 原始证据

- verification/bdrip-media-parameters-20261106.json：八个样片SHA-256、ffprobe format/streams、音频/字幕/附件/色彩/HDR信息。文件名不作为参数依据。
- verification/bdrip-default-playback-results-20261106.json、bdrip-enhanced-playback-results-20261106.json、bdrip-physical-playback-results-20261106.json：逐样片请求模式、实际hwdec、像素格式、尺寸、音轨、瞬时掉帧、avsync、截图大小、错误。
- verification/decode-windows-matrix-20261106.txt：默认引擎原始14项通过。
- verification/bdrip-default-final-matrix-20261106.txt：同库绑定修复后默认引擎18项通过，新增AAC与字体附件容器。
- verification/bdrip-enhanced-playback-20261106.txt：增强引擎首次视频访问冲突，不能计为通过。
- verification/bdrip-enhanced-playback-fixed-20261106.txt：修复后14项通过。
- verification/bdrip-physical-matrix-20261106.txt：2407FRK8EC / Android16 / ARM64，17通过、1跳过；跳过原生ASS专项。
- verification/bdrip-watchpage-soak-windows-20261106.txt：正式WatchPage、临时SQLite/内存设置，4K Main10循环601秒、120采样，1项通过。
- verification/bdrip-watchpage-soak-physical-20261106.txt：真机正式WatchPage：601秒、119采样、进度落盘和释放通过；1项通过。

## 样片与范围

|样片|编码/音轨|范围|
|---|---|---|
|h264-8-1080.mkv|H264 8bit 1080p、FLAC mono48k|本地no/auto，暂停恢复/2秒跳转；同一文件本地模拟HTTP Range|
|h264-aac.mkv|H264 8bit、AAC mono48k|Windows默认与真机本地no/auto|
|h264-hi10-1080.mkv|High10 / yuv420p10le、FLAC|本地no/auto；Windows自动软解；真机auto后端报告mediacodec|
|hevc-main10-1080.mkv|Main10 / yuv420p10le、FLAC|本地no/auto|
|hevc-main10-4k.mkv|Main10 3840×2160、FLAC|本地no/auto；Windows正式页十分钟；真机正式页601秒通过|
|hevc-main10-4k-hdr.mkv|Main10、BT2020/PQ、HDR静态标记、FLAC|只验证可解码、元数据和跳转；不是HDR精度验收|
|hevc-multi-font.mkv|Main10、FLAC stereo与AAC stereo、ASS、OTF附件|视频和首选FLAC本地测试；真机内封ASS与Noto字体原生绘制另有专项通过，截图检查中文字形可读；复杂特效及音轨切换未全覆盖|
|hevc-truehd-aac.mkv|Main10、TrueHD5.1与AAC备用|默认实际TrueHD失败、显式AAC恢复通过；增强TrueHD解码/AAC切换通过；未做声学验收|

字体仅在测试目录：Noto Sans CJK SC，来自官方notofonts/noto-cjk，SIL OFL许可证同目录保留；未打包到产品。测试目录位于.dart_tool，不提交大媒体。

Windows默认首轮瞬时frame-drop-count为0或1；增强为0或1；真机首轮采样均0。它们不是十分钟累计掉帧。Windows正式页循环会重置计数，不能加总为“全程零丢帧”。Windows观察RSS峰值831295488字节、末次519655424字节；不能据单次运行证明无泄漏。音画同步只记录采样时avsync，没有外部声画测量。

## 可复现与设备保护

1. tool/generate_playback_fixtures.ps1用指定ffmpeg生成基础五样片，拒绝覆盖；tool/extend_playback_fixtures.ps1生成AAC/字体附件/TrueHD扩展样片。
2. tool/serve_playback_fixtures.cjs只绑定127.0.0.1，只允许读取样片；tool/stage_android_playback_fixtures.ps1仅建立adb reverse。
3. Android使用CCPLAYER_ISOLATED_VALIDATION=1构建独立包com.clainst.ccplayer.validation；先完成构建并核对APK实际包名，再允许安装。测试使用--no-uninstall，禁止在有用户数据设备直接使用默认包集成测试。
4. Flutter测试框架在启动前缓存旧APK包信息；本轮首次真机安装被拒后，其清理行为疑似移除了正式包。前后pm列表已确认原包消失；用户随后确认无须保留的数据，并授权重新安装。独立包已安装成功，后续关闭自动卸载。不能声称本轮未影响真实设备。
5. 真机首次两次安装被系统拒绝，用户准备好后直接adb install成功；这些失败未计为播放通过。
6. Android首轮13项（1跳过）均因未推进Surface挂接时序而失败；修复测试pump并等待真实video-params后真机17通过。模拟器修正后仍需复测，不把测试代码修正当作通过。

没有真实云盘读写、Bangumi写入、用户视频转码、媒体库覆盖或数据库迁移。真机正式应用卸载事件除外，见上文。

最终扩展Windows默认与增强各18项播放回归通过。真机正式页RSS观测范围及最终值见日志；默认copy路径输出8-bit的问题仍未解决。

## 最终设备补测

- 真机bdrip-physical-details-20261106.txt：原生完整能力查询与内封ASS/附件字体绘制，2项通过；实际126解码器，缺truehd/mlp。截图physical-native-ass.png位于合成样片目录，已人工查看简繁字形。该测试显式libass=true，Android产品设置仍未开放该选项。
- 真机正式页RSS观测峰值944148480字节，600秒采样912793600字节；计数可随4秒循环重置，不能称全程零丢帧或无泄漏。
- 模拟器：首轮13失败/1跳过；修正Surface时序后仍视频输出超时；扩展矩阵在持续失败后中断；另用swiftshader_indirect重启做H264软件解码单项，0通过/1失败。日志有EGL_BAD_ATTRIBUTE，但尚未定位完整根因，不能声称修复。完整原生能力查询通过并已保存，硬解未验收。
- 正常CCPlayer Debug包com.clainst.ccplayer已重新构建、安装成功并启动；独立.validation包保留，测试自动卸载关闭。
