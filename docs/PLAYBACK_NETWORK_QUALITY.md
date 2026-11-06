# 播放质量与CloudDrive2 WebDAV：阶段一

日期：2026-11-06。当前完成网络正确性修复与只读诊断，**不是整个附件任务验收完成**。开始前已检查Git状态与实际源码，保留大量既有修改；本轮没有修改数据库、身份关系、同步机制、刮削分类、MPV配置文件或依赖。

## 已完成

### 原始字节与Range

- 新增`lib/core/webdav_stream.dart`，由现有StreamBroker调用。传递的是HTTP响应的媒体字节，不做视频解码、转码、码率选择或临时视频生成；字幕仍独立取得票据。
- 只允许GET/HEAD；支持单段闭区间、开放区间和后缀区间，拒绝无法处理的多区间及非法范围。不会假装支持multipart响应。
- 206必须具有语法正确且与请求匹配的Content-Range；已知总长度不得小于末字节位置，Content-Length若存在必须等于区间长度。缺少长度但范围有效时可从范围确定响应长度。错误头在转发响应体前拒绝。
- Range意外收到200时，仅在请求本来就是从0开始的无上限流，或已知完整实体确实落在所请求的范围内时透传真正200。其他情况返回502、关闭上游，不跳过前面的字节、不伪造206、不主动重试下载全文件。HEAD不读取正文，因此允许服务器忽略其Range并返回200头。
- 200无Range支持未知长度的流式读取。设置Accept-Encoding: identity并禁用自动解压；成功响应若仍含gzip等编码则拒绝，避免压缩后的字节偏移被误作媒体范围。
- 416保留合法`bytes */length`，不转发任意错误页面；其他错误保留状态且不转发可能很大的正文。
- 已知长度短读/断连保持失败；已经提交的响应发生错误时关闭连接，不能改成一段假成功视频。

### 重定向与取消

- 最多5次显式重定向，保留GET/HEAD和Range；只允许HTTP(S)，拒绝带userinfo的重定向及HTTPS降级。
- DAV认证仅发往原始精确origin（scheme/host/port均匹配），不把Authorization/Cookie附带到不同来源的签名/CDN地址；不把真实地址传给下游播放器或写日志。保留原站认证挑战处理。
- 每个票据拥有独立连接组；票据撤销关闭其所有活动HTTP连接。页面关闭会撤销主播放、字幕及独立预览票据，异步签发在页面已退出时也立即撤销。
- 不因新的Range到达就取消同票据全部请求，避免破坏MPV合法的并发读取；过时连接由其下游断开回收。预览与主播放票据分开，后续可独立取消。
- 测试证明`HttpResponse.done`不足以检测“上游挂起时下游退出”。成功GET在写HTTP头后接管该响应socket，监听下游读端关闭/错误并取消上游；输出仍使用流背压。已知长度按Content-Length传递；未知完整响应使用真实HTTP分块编码，分块标记不进入媒体内容。不发送任何探测/心跳字节到视频。
- 下游响应声明Connection: close，每次传输后释放该本地连接，不在已经接管的socket上承接下一条HTTP请求；MPV仍可向broker建立多条请求，无全局低并发锁。
- 连接/响应头上限15秒，正文仅设置30秒无数据等待，不设总视频时长上限。长时间正常流式读取不会因总时长被取消；尚需真实高码率和暂停/恢复长期验收。

### 调试指标

仅启用应用调试日志开关时写入方法分类、上下游状态、已知范围长度、读取字节数、耗时、取消状态、缓存命中false及playback/preview/subtitle用途。不记录路径、URL、票据、异常正文或认证头。这里没有增加网络视频缓存，因此不会虚报缓存命中。开放/后缀范围不能事先计算长度时记录-1。

### 播放统计

新增只读MPV版本、hwdec设置、解码/底层像素格式、色彩矩阵/原色/传递函数/范围、current-vo、滤镜后视频尺寸、paused-for-cache；保留原hwdec-current、源尺寸、掉帧、缓存和音频统计。

Flutter纹理尺寸单独读取VideoController.rect，零尺寸和缺失值为未知。只对少量已确认的FFmpeg 8/10-bit像素格式识别解码分量位深；d3d11/mediacodec等不透明格式不推断，平均bpp不当作分量位深。这些都不能证明屏幕输出位深或HDR能力。未实现自定义引擎名称标记，仅显示实际可读的mpv-version；未知字段三语显示“未知/Unknown”。

## 当前解码、渲染与配置审查（源码证据，非本轮运行采样）

| 项目 | 当前实现与限制 |
|---|---|
| Windows解码 | native_video_controller默认hwdec=auto，未强制固定GPU后端。本轮未改变设置，未证明实际视频使用了硬解。 |
| Android解码 | 物理设备默认auto-safe；getDefaultHwdec按现有设备检测对模拟器返回no。保留原策略；无真实SoC软硬解/HDR验收。 |
| Windows输出 | angle_surface_manager.cc使用DXGI_FORMAT_B8G8R8A8_UNORM；video_output.cc交给Flutter的格式为BGRA8888。保留此稳定路径，不声称端到端10-bit。 |
| Android输出 | VideoOutput.java通过Flutter SurfaceProducer获取Surface并设置尺寸；Dart控制器配置Android GPU上下文。仅此不能证明Surface、系统合成或屏幕以10-bit/HDR工作。 |
| 原始视频 | 从HTTP读取媒体字节，不改变编码或码率；无法仅凭代理源码证明真实CloudDrive2服务没有在其内部替换或转码。真实服务未访问。 |
| 默认缩放 | 无自定义配置目录时库设置scale/dscale=bilinear、dither=no；另有correct-downscaling、linear-downscaling、sigmoid-upscaling、hdr-compute-peak=no。没有改成新预设。 |
| 自定义配置 | config/config-dir/input-conf在libmpv初始化前设置；库后续仍写运行期属性，VideoController再写vo/hwdec。部分参数会覆盖用户配置，这是下一阶段需要有针对性验证并修复的冲突。不能宣称全部用户画质参数已得到尊重。 |
| 缩放与HDR质量 | 尚无同帧、同尺寸、同色彩设置下的画质比较；没有添加补帧、锐化、去噪、AI超分或默认降分辨率。 |

源码位置：`packages/media_kit/lib/src/player/native/player/real.dart`初始化及properties；`packages/media_kit_video/lib/src/video_controller/{native_video_controller,android_video_controller}/real.dart`；`packages/media_kit_video/windows/{angle_surface_manager.cc,video_output.cc}`；Android `VideoOutput.java`。本轮这些依赖文件均未编辑。

## CloudDrive2请求风险对比

| 情况 | 修改前 | 本轮后 |
|---|---|---|
| Range被忽略返回200 | 直接转发完整正文 | 非安全退化拒绝，停止上游；不主动补下载 |
| 206范围/长度错误 | 直接转发 | 头部校验；正文截断不伪装成功 |
| 重定向 | 自动跟随，行为由HttpClient决定 | 有限显式跟随，精确origin限定凭据 |
| 播放页退出 | 票据持续存在、无撤销接口 | 撤销当前页面全部票据与其HTTP连接 |
| 客户端断开、上游挂起 | 继续等待上游 | socket读端检测并关闭上游 |
| 反复拖动 | 无校验的独立请求 | 校验每个请求，保留正常并发，不做全局串行 |
| 预览 | 与主播放共用同一票据 | 独立用途票据；仍默认关闭 |
| 扫描与限流 | 原只读PROPFIND | 本轮未改；可配置节奏/取消/Retry-After退避仍待实现 |

## 实际验证

- 新增webdav_stream_test.dart 8项：200/206/416/HEAD、闭区间/开放/后缀、未知长度分块、意外200、错误Content-Range/长度/编码、客户端/上游断连、签名式跨origin重定向、20次并发跳转、票据撤销及日志隐私。
- 传输测试用本地生成的确定性二进制字节，逐字节比较代理响应；不是实际视频解码/高码率性能或CloudDrive2真实负载测试。
- 新增playback_diagnostics_test.dart 3项：不透明格式不猜位深、源/滤镜/纹理尺寸分离、窄屏统计未知值与纹理读数。数值是明确的模拟读属性，不是设备采样证据。
- 网络/诊断/既有播放器专项16项通过；最终静态分析0问题；全量**293通过、6跳过、0失败**。曾发现测试HEAD断言误置于模拟服务器关闭之后，已修复并完整重跑。
- 报告：verification/webdav-range-analyze-20261106.txt、webdav-range-regression-20261106.txt。双端最终编译结果见开发进度，未进行实际视频播放验收。
- Windows Debug编译成功（10.5秒），`build/windows/x64/runner/Debug/CCPlayer.exe`；Android Debug APK编译成功（Gradle26.3秒），`build/app/outputs/flutter-apk/app-debug.apk`。报告为verification/webdav-range-{windows,android}-build-20261106.txt。没有安装或运行进行本轮真机/模拟器播放矩阵验收。

## 未完成、限制与下一阶段

1. 软件/自动/硬件优先设置UI与持久化、错误硬解选项可恢复性、用户配置冲突修复；不能把源码默认值当实际解码结果。
2. 兼容/均衡/高画质/自定义预设及逐平台实测；未改变已有默认质量策略。BGRA8链路保持不变；真正高位深链路若需改核心接口须先说明取舍并征求用户同意。
3. 预览已有默认关闭、200ms合并等待、过代结果丢弃、24帧缓存及播放器退出时销毁；本轮只做票据隔离/退出回收。仍缺帧量化、网络预算、立即中止正在进行的原生预览解码及关闭预览后的主动资源回收。
4. 扫描节奏、取消、429/Retry-After有界退避与播放优先调度未实现，403仍不可笼统当限流。
5. 未执行附件中的H.264/HEVC Main10 1080p/4K、HDR10、高码率BDRIP+FLAC、ASS字幕矩阵，未进行默认/增强MPV同帧比较。没有新增或重编码真实媒体文件，没有真实Android硬件验收，亦没有本轮模拟器播放验收。
6. 对200正文若服务器声明了一个较小且自洽的Content-Length，且没有独立可信实体尺寸/验证器，仅凭该HTTP消息无法证明源文件其实更长。当前能检测206头部不一致和传输截断，不承诺识别所有服务器谎报大小。未知长度200自然结束也无法单凭HTTP区分源自然结束和未声明长度的截断。
7. HTTP中继没有主动缓存/整文件读取；这不约束MPV自己的缓存行为。未做真实网络总读取量或并行预览带宽测量，不宣称完成防过量预读验收。

## 关键修改与回退

- `lib/core/webdav_stream.dart:7/36/195/294`：票据中继、协议校验、可取消socket输出、安全200判断。
- `lib/core/sources.dart:370/401/422`：票据签发、撤销与新中继接线。
- `lib/ui/watch_page.dart:65/146/172/270/624`：页面票据跟踪、预览/字幕分离、退出回收与纹理只读统计。
- `lib/core/playback_probe.dart:36/64/91`及`lib/ui/playback_inspector.dart:70/150`：只读属性与展示；三语ARB及生成文件随新增字段更新。
- 新增两个专项测试；开发进度及本文件记录真实范围。不涉及数据库迁移、媒体文件修改、用户MPV配置修改或新增依赖。
- 回退应仅逆向本轮这些局部修改：先恢复StreamBroker的旧HTTP接线并移除票据回收接线，再移除新中继；诊断可独立回退新增字段/标签。**不要git reset、git restore整个文件或清理未跟踪文件**，当前文件含大量用户既有修改。旧中继没有本轮Range保护，回退会恢复已知网络风险。
- 本轮没有可供整体覆盖的干净基线；需要回退时应逐块核对当前代码与本轮改动，不覆盖此前同步/播放器成果。无需迁移或恢复数据库，无需改动用户配置或媒体。

依据：[HTTP Range/部分响应语义 RFC9110](https://www.rfc-editor.org/rfc/rfc9110.html#section-14)、[Dart重定向API](https://api.dart.dev/dart-io/HttpClientRequest/followRedirects.html)、[MPV属性手册](https://mpv.io/manual/stable/#property-list)、[FFmpeg像素格式定义](https://github.com/FFmpeg/FFmpeg/blob/master/libavutil/pixfmt.h)。上述资料用于协议和字段核对，不代替实际设备验收。
