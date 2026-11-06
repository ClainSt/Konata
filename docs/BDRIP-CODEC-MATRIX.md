# BDRIP-CODEC-MATRIX

日期：2026-11-06。结论只适用于记录的二进制、设备和合成样片，不能外推到全部 BDRip。

## 状态定义

1. **已在真实 CCPlayer 中验证通过**：正式 WatchPage，隔离临时媒体库；通过范围以具体用例为准。
2. **仅本地自动化测试通过**：真实 libmpv + Flutter Video 的隔离播放测试，未覆盖正式产品全部交互。
3. **理论支持，但尚未实测**：当前原生库提供解码器；没有相应样片播放证据。缺样片时仍须写明未测试。
4. **已确认不支持或存在缺陷**：实际失败或当前安装包能力缺失；不得用主机 FFmpeg 能力代替。

## 实际库

|平台|MPV / FFmpeg|可查询解码器|备注|
|---|---|---|---|
|Windows 默认|0.36.0-403-g652a1dd907 / n6.0|135|无 Lua、Vulkan、libplacebo；有 libass、ANGLE|
|Windows 增强（隔离安装）|0.42.0-1-g3138fc8ee / N-128420-gbaa68e68b|524|有 Lua、Vulkan、libplacebo、libass；未激活到用户设置|
|Android x86_64 模拟器|0.36.0-549-g78d43740f5-dirty / n6.0|126|软件解码保护；不代表 ARM64 或真机硬解|
|Android ARM64 真机 2407FRK8EC / Android 16|0.36.0-549-g78d43740f5-dirty / n6.0|126（已查询ARM64）|实际 MediaCodec 和 mediacodec-copy 已观察到|

完整 Windows 清单见 verification/bdrip-default-codecs-20261106.json 与 bdrip-enhanced-codecs-20261106.json。Android 已查询 FFmpeg 编译字符串；Windows相关 C 导出不可用，不能声称得到完整 FFmpeg 配置。软件解码器、硬解后端、gpu/libmpv 渲染输出是三个不同层次。

## 编码组合

|组合|Windows 默认|Windows 增强|Android 真机|Android 模拟器|
|---|---|---|---|---|
|H.264 8-bit + FLAC|状态2；软解 / d3d11va-copy|状态2；软解 / d3d11va|状态2；软解 / mediacodec|状态4：当前模拟器视频输出失败；软件图形后端对照亦失败|
|H.264 8-bit + AAC / BT.709|状态2；新增样片复测通过|状态2；软解 / d3d11va|状态2；软解 / mediacodec|待复测|
|H.264 Hi10P + FLAC|状态2；软解，auto回退软解|状态2；软解，auto回退软解|状态2；软解可用；auto报告mediacodec，精度未确认|待复测|
|HEVC Main10 1080p + FLAC|状态2；软解 / d3d11va-copy|状态2；软解 / d3d11va|状态2；软解 / mediacodec|待复测|
|HEVC Main10 4K + FLAC / SDR|状态1；正式播放页601秒；另有状态2软解测试|状态2；软解 / d3d11va；未做10分钟|状态2；软解 / mediacodec；状态1；正式页601秒完成|待复测|
|HEVC Main10 + FLAC/AAC双音轨 + ASS/字体附件|视频和首选FLAC状态2；切轨与字体渲染待专项|视频和首选FLAC状态2，字体待专项|视频/FLAC状态2；内封ASS和Noto字体状态2，截图字形已检查|未测试|
|HEVC Main10 4K + HDR10标记 / FLAC|状态2；源PQ/BT.2020可读取|状态2；源PQ/BT.2020可读取|状态2；软解 / mediacodec 可播放|待复测|
|HEVC + TrueHD 5.1 / AAC备用|当前解码器清单缺少truehd/mlp，状态4；样片实际解码初始化失败，AAC显式恢复通过|状态2；真实TrueHD解码与AAC切换通过（null音频输出）|状态4：ARM64清单缺truehd/mlp；未做音轨播放|状态4：x86_64清单缺truehd/mlp|
|AV1 10-bit + Opus|解码器存在，状态3，无样片|解码器存在，状态3，无样片|未测试|未测试|
|MPEG2/VC1 + AC3/DTS / 1080i|解码器存在，状态3；反交错无样片|解码器存在，状态3；反交错无样片|未测试|未测试|
|DTS-HD MA / 多声道映射|未测试；dca存在不等于已验证DTS-HD MA|未测试|未测试|未测试|
|HEVC 422/444/12-bit、HDR10+、DV各Profile、直通|未测试|未测试|未测试|未测试|

## 质量限制

- Windows BGRA8 共享纹理未改变；源10-bit / P010不等于最终显示链路10-bit。
- 真机正式页默认auto-safe / mediacodec-copy对Main10样片报告yuv420p（8-bit），未证明保留原始10-bit精度；保留安全默认，不强推直接硬解。
- HDR样片由自制图案加HDR元数据生成，编码值不是HDR校准参考。HDR10→SDR精度、HDR显示精度和音频直通均**需专用显示/音频设备验证**。
- 截图和音轨参数不能证明主观无色带、无杂音、声道映射正确；这些仍需视听验收。

模拟器首轮13项失败；修正时序后的扩展复测在持续失败后中断，不能视作完整矩阵。切换软件图形后端的H264最小对照仍超时（bdrip-emulator-swiftshader-probe-20261106.txt）。其余格式标为未测/待复测，不据此推断编码不支持。Android两架构完整清单见bdrip-physical-codecs-20261106.json与bdrip-android-codecs-20261106.json。

Windows普通PE导入清单与DLL摘要见verification/bdrip-*-pe-imports-20261106.json；未见独立avcodec/avformat DLL普通导入，增强版包含vulkan-1.dll。该检查不覆盖延迟或动态加载，不能据此声称没有其他依赖。Android真实FFmpeg配置为静态构建并启用受限解码器白名单。
