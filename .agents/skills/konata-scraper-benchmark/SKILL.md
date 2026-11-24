---
name: konata-scraper-benchmark
description: >-
  Konata v3 刮削与解析引擎（packages/engines/engine_scraping）的架构边界、保真红线、纯 Dart 回归测试与
  eval_scraper 离线评测工作流。修改或调试文件名解析、目录分类、合集拆分、集号提取、特典归组或 Bangumi/TMDB 匹配时激活。
---

# Konata v3 刮削引擎开发与回归评测工作流

本引擎位于 `packages/engines/engine_scraping/`，是 Konata 最核心的纯 Dart 护城河，修改前必须先核对下列边界与红线。

## 1. 纯 Dart 架构与模块边界

- **严格 0 Flutter、0 Riverpod 依赖**：所有测试直接走 `dart test`（比 `flutter test` 快 3~5 倍）。
- **唯一公开出口**：外部仅可通过 `package:engine_scraping/engine_scraping.dart` 调用，严禁外部深入 `lib/src/`。
- **有序管道**：解析、目录分析、合集拆分、多版本归组、`WorkMatcher` 多信号打分与 TMDB/Bangumi/Fanart 客户端通过有序 `ScrapePipeline` 串联，所有关键决策写入 `DiagnosticLogPort`。
- **艺术图统一用 `ArtworkRef`**：远程来源输出 `remote(tmdb | bangumi | fanart, uri, locked)`，严禁回写本地路径污染同步元数据。

## 2. 绝对不可违背的业务红线

1. **零简化、零缩水**：严禁为了压缩代码行数而合并、删减任何数字番名保护（如 `86`、`100`、`0`）、季级后缀拆分、split-cour 累计集号对齐、特典限定词（如 `Character PV` vs `PV`）识别或匹配打分规则。
2. **媒体源严格只读**：绝不在用户本地/WebDAV/SMB 目录写入 `.nfo`、图片或改名文件。
3. **扫库/刮削期零流探测**：仅依据路径名与目录清单文件大小分类，严禁在扫描期跑 `ffprobe` 或读取文件头/全文件哈希。
4. **宁缺毋滥与错误隔离**：绝不压低 `WorkMatcher` 阈值硬贴错误海报；网络瞬态错误（超时、429、5xx）绝不覆盖已有元数据或覆写 `manual_lock`。

## 3. 必备验证命令

1. 边界与静态分析：
   ```powershell
   dart run tool/verify.dart guard
   dart run tool/verify.dart analyze packages/engines/engine_scraping
   ```
2. 纯 Dart 回归测试：
   ```powershell
   dart run tool/verify.dart test packages/engines/engine_scraping
   ```
3. 离线基准评测（对标只读基线 `4ee643f`，准确率严禁回退）：
   ```powershell
   dart run packages/engines/engine_scraping/tool/eval_scraper.dart
   ```
