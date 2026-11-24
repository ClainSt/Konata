# engine_sources

Konata v3 纯 Dart 媒体源访问、统一网络传输与本地回环流网桥引擎。

## 职责边界

- **严格 0 Flutter、0 Riverpod、0 `build_runner` 依赖**，仅依赖 `konata_contracts` 与 `konata_storage`。
- 唯一公开出口：`package:engine_sources/engine_sources.dart`。
- 核心能力：
  - 统一 `KonataHttpClient`（官方优先 + 备用自动容灾、DoH/SNI、系统/自定义代理、域名冷却、`PriorityHttpScheduler`）；
  - Local / WebDAV（Digest 认证与连接池）/ SMB（`smb_connect`）只读媒体源网关、凭据存储（基于 `SecureStoragePort`）、路径校验与 7 类错误归类；
  - 目录遍历扫描器 `DirectoryScanner`、断点快照与频控节流策略、外挂字幕匹配器 `SubtitleMatcher`；
  - `LocalStreamBridge` 本地 `127.0.0.1` 按需 HTTP 206 流网桥、滑动窗口预读器、虚拟 `.cue`/`.m3u8` 专辑目录；
  - `WorkDetailWarmupService` 详情页静默连接池与字幕目录预热服务。
- 媒体源严格只读，绝不向用户本地或远端媒体目录写入或删除任何物理文件。
