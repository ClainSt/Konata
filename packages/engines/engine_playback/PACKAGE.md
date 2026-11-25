# engine_playback

Konata v3 纯 Dart 统一播放内核、`libmpv` 原生接口绑定、字幕内存直注与发烧音频安全链引擎。

## 职责边界

- **严格 0 Flutter、0 Riverpod、0 `build_runner` 依赖**，全部平台纹理/表面/媒体会话/相册发布能力均抽象为纯 Dart 桥接端口。
- 唯一公开出口：`package:engine_playback/engine_playback.dart`。
- 核心能力：
  - `UnifiedPlaybackEngine` 四维代数隔离（物理媒体代数、逻辑曲目代数、四域任务令牌、主流与预取流租约）；
  - `libmpv` FFI 绑定与会话核心、画质配置与自适应策略、Hi10P 硬件解码安全回退、发烧音频 `-12 dBFS` 音量保护链；
  - `SubtitleMemoryEngine` 支持字幕编码归一、内存直注、`FontInAss` 云端子集化与单级字体池。OpenCC 与旧编码表按需读取打包资产，旧编码按页解压，退出播放时释放缓存。
  - CUE/LRC 解析与分轨映射、片头片尾章节跳播分析、观看进度追踪与外部播放器/接力协议追踪核心；
  - `tool/generate_codec_matrix.dart` 编码矩阵微样本生成工具。
