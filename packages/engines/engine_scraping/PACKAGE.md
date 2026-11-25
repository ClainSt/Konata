# engine_scraping

Konata v3 纯 Dart 番剧文件解析、合集拆分、多源匹配打分与有序刮削管道引擎。

## 职责边界

- **严格 0 Flutter、0 Riverpod、0 `build_runner` 依赖**。
- 唯一公开出口：`package:engine_scraping/engine_scraping.dart`。
- 核心能力：
  - 无损继承 `4ee643f` 全部 BDRip 解析规则、压制组词表、标题归一、数字番名保护、合集拆簇、季零拆分、附属资源路由；
  - `WorkMatcher` 多信号打分、多版本归并、系列自动串联、疑难作品救援、四通道上墙资格与艺术图优选（统一输出 `ArtworkRef`）；
  - TMDB / Bangumi / Fanart.tv 客户端、Bangumi-TMDB 离线二进制索引与纯 Dart 静默热更新器；
  - 有序 `ScrapePipeline` 与全离线评测工具 `tool/eval_scraper.dart`（准确率严禁回退）。
- 目录枚举、断点快照、频控与字幕匹配复用 `engine_sources`，刮削入口向共享扫描器注入完整识别规则。
- 随包映射由宿主经 `AssetDataLoaderPort` 读入，已校验的本机更新与包内快照按版本和日期择优生效。
- 发行组词表由宿主按需读取，刮削计算会话启动时把同一份压缩数据传给其后台隔离线程。
- 刮削期零流探测、媒体源严格只读、绝不简化核心规则。

- 归集、重组及持久化透传云盘远端文件标识，不通过文件哈希识别云盘内容。
