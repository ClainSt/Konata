# 《86》第一集 SDR 播放验收 · 2026-11-06

以同一台设备上的独立 mpv 播放本地文件为参照，CCPlayer 通过正式播放页面访问真实 WebDAV，自动选择简中 ASS。两端采用隔离测试构建及默认播放输出。原片为 1920×1080 HEVC Main10、24000/1001 fps，文件 1,284,006,743 字节，SHA-256 为 `613f342d4840f45382f5ec0689c0938fc70f603f30f185e2f7b7e3855e3a6319`。手机本地原片与参考字幕均校验过，独立播放器显式加载同份字幕。

## 同帧画面

Windows 独立 mpv 使用本机便携配置，CCPlayer 使用默认纹理输出，两者解码输出均为 p010。Android 独立 mpv 采用 MediaCodec 直接硬解，CCPlayer 默认回拷输出 yuv420p，另以 CCPlayer 10 位软件解码作对照。比较均在同机同尺寸的屏幕合成图上进行，截图为 8 位。

| 片内时间 | 结果 |
|---|---|
| 22.022 秒暮色、37.704 秒雾气、137.012 秒暗衣 | Android 回拷与直接硬解的局部平均绝对亮度差依次为 0.379、0.367、0.341 个 8 位灰阶。三个区域回拷与软件解码的最大差均为 2 级。|
| 123.957 秒细线 | Windows 和 Android 相对参照的平均绝对亮度差分别为 0.741、0.474 级。Windows 默认纹理在该区域边缘略柔。|
| 176.218 秒位置字幕 | 两端均显示简中 ASS；CCPlayer 与参考字幕像素遮罩的交并比分别约 0.76、0.78。|
| 1388.345 秒双行卡拉 OK | Windows 参考配置允许字幕进入上下黑边，CCPlayer 两行均在画内。Android 垂直位置接近，但字宽、轮廓有差异，遮罩交并比 0.316。|

在相同裁区计算 CAMBI，暮色、雾气、暗衣的参考直接硬解分数依次为 0.927、3.174、3.452，回拷为 0.074、0.866、1.701，软件解码为 0.535、1.829、2.774。三处均未发现回拷加重色带的证据。仅比较同场景分数，截图无法证明面板具有端到端 10 位精度。[CAMBI 指标说明](https://github.com/Netflix/vmaf/blob/master/resource/doc/cambi.md)

## 运动及同步

19:04.75 起取连续横移，22:15 起取 15 秒平均约 31.05 Mbit/s 的高码率段。每端每播放器每段约 15 秒，八组解码和输出掉帧计数增量均为零，采样未观察到因缓存暂停。

| 平台和指标（P95，毫秒） | 横移：独立 / CCPlayer | 高码率：独立 / CCPlayer |
|---|---:|---:|
| Windows 桌面呈现间隔 | 42.83 / 45.82 | 42.82 / 47.24 |
| Android 可辨画面变化间隔 | 43.49 / 50.87 | 124.34 / 125.09 |
| Windows 播放器时钟绝对音画差 | 0.011 / 1.287 | 0.011 / 1.614 |
| Android 播放器时钟绝对音画差 | 0.033 / 0.037 | 0.032 / 0.046 |

Windows 采用 DXGI 桌面复制呈现时间。CCPlayer 横移首轮采集边界出现一次 355 毫秒间隔；预热一秒复测，横移最大 50.65 毫秒、高码率最大 54.10 毫秒，未复现。Android Flutter 图层包含重复提交，故独立录屏约 12 秒，按原片可区分的画面变化比对。横移两组各自采集区间匹配 289/289、287/287 组，高码率段为 232/232、230/230 组。高码率段原画有重复帧。录屏会引入负载，时钟差来自播放器内部，声光端到端延迟未测量。

结论：保留解码与缓存默认值。若要进一步对齐本机参考，优先复核 Windows ASS 边距、Android ASS 字体匹配及横移呈现间隔。本轮仅验收 SDR 指定片段。

[结构化测量记录](verification/sdr-playback-acceptance-20261106.json) · [Android 雾气原尺寸裁图，依次为直接、回拷、软件](verification/sdr-android-mist-comparison.png) · [Android 细线](verification/sdr-android-fine-lines.png) · [Windows 双行字幕](verification/sdr-windows-karaoke.png) · [Android 双行字幕](verification/sdr-android-karaoke.png)

## 11 月 7 日复测：Windows 全屏 ASS 黑边

默认纹理原先只包含视频矩形，屏幕黑边由 Flutter 在纹理外绘制，libass 无法使用该区域。现复用已有的纹理尺寸接口，把上下黑边纳入全屏字幕画布，并在默认 Windows libass 配置中启用字幕边距。退出全屏后恢复原有纹理尺寸；启用自定义 mpv.conf 时，字幕选项交给用户的配置。调整范围为 Windows，全屏测试片源仍采用 D3D11VA 回拷 p010。

| 3200×2000 屏幕，同帧字幕垂直范围（像素，含首尾） | 独立 mpv 本地 | CCPlayer WebDAV 调整前 | 调整后 |
|---|---:|---:|---:|
| 1388.345 秒上行歌词 | 25–90 | 124–199 | 28–92 |
| 1388.345 秒下行歌词 | 1892–1971 | 1793–1879 | 1896–1974 |
| 176.218 秒片内定位字幕 | 1519–1648 | 1523–1652 | 1523–1652 |

同帧亮度对比中，暗衣与细线裁区调整前后最大变化均为 1 个 8 位灰阶。双行歌词相对参考的像素遮罩交并比由 0 升至 0.184，边距达到了本轮目标，字体轮廓仍有差异。测试分辨率下纹理由 1920×1080 扩到 1920×1200，每张 4 字节/像素纹理约增加 0.88 MiB，不代表整个进程的实测显存增量。本次复用现有插件，未引入字体包、磁盘缓存或第三方依赖。若偏好画内歌词，可启用自定义 mpv.conf 并设置 `sub-ass-force-margins=no`。

[修复后双图：左为本地独立 mpv、右为 WebDAV CCPlayer](verification/windows-ass-margins-20261107.png) · [同帧字幕遮罩和画面差异](verification/windows-ass-margins-20261107.json)

## 11 月 7 日复测：双端 ASS 字宽与轮廓

《86》第一集 23:08.345，上行请求 DFGSoGei-W7，下行请求方正综艺_GBK，两行均请求斜体。读取 libass 的 fontselect 日志，区分 ASS 请求名与实际选中的字体。Windows 的独立 mpv 与 CCPlayer 测试均直接读取各自的选字日志。手机独立 mpv 的选字日志来自同一集原视频段与原 ASS 无重编码封装的本地诊断片段；屏幕对照参考采用前轮独立 mpv 播放完整本地原片时保留的同帧。CCPlayer 通过正式播放页面自动选中真实 WebDAV 的简中字幕。两端都用同一时刻关闭字幕的截图提取字形，遮罩阈值为灰阶差大于 12。

| 平台 | 字体选择与修复 | 独立 mpv 上／下行宽 | CCPlayer 修复前 → 后 | 字幕遮罩交并比 |
|---|---|---:|---:|---:|
| Windows | CCPlayer 原选 Arial-ItalicMT 并以 MicrosoftYaHeiUI 补字。参考两行均选 LXGWWenKaiMonoLite-Regular。本机 CCPlayer 配置直接引用独立 mpv 已安装的字体，保留原边距、双线性缩放和抖动设置 | 1739／1408 px | 1628／1321 → 1740／1409 px | 0.1841 → 0.7690 |
| Android | CCPlayer 原选 NotoSansCJKSC-Regular。官方 mpv 实际记录 Roboto-Italic、MisansTCVF 与 MiSansVF。CCPlayer 在安装了 MiSansVF 的手机上使用系统 MiSans VF 作为缺失字体的默认回退，同时保留原有 Noto 字体链接。实机日志确认两行均选 MiSansVF | 1065／853 px | 983／786 → 1061／848 px | 0.3164 → 0.6943 |

Windows 上行垂直范围为 24–90 px（参考 25–90），下行 1892–1971 px 与参考相同。02:56.218 的片内定位字幕上下边也对齐，遮罩交并比为 0.9707。双端在两个时间点关闭字幕后，修改前后完整视频矩形的 RGB24 像素哈希分别相同。以上结论限于这两帧。

Android 另试只使用 MiSans TC，歌词遮罩交并比 0.6956，相对 MiSans VF 的收益仅 0.0013，故保留 MiSans VF 方案。两端仍有轮廓差异。手机 CCPlayer 的 1920×1080 字幕合成纹理与独立 mpv 的 2712×1220 屏幕画布不同，当前测试未把字体选择、光栅化尺寸及库版本的剩余影响逐项分离。

Windows 复用现有本机字体，可关闭自定义 mpv 配置回退；发布包无需包含字体。Android 额外创建至多一个系统字体符号链接，使用系统已有约 19.1 MiB 的 MiSans 文件，无需下载或复制。未测量字体加载带来的进程内存峰值。手机可在自定义 mpv.conf 指定原来的 `sub-font=Noto Sans CJK SC`。本轮 Android 修复验证使用隔离包。

[Windows 同帧对照](verification/ass-fonts-20261107-windows.png) · [Android 同帧对照](verification/ass-fonts-20261107-android.png) · [Windows 遮罩与 RGB 哈希](verification/ass-fonts-20261107-windows.json) · [Android 遮罩与 RGB 哈希](verification/ass-fonts-20261107-android.json)
