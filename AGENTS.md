# Konata v3 全局开发宪章（AGENTS.md）

本文件是 `D:\Anime-Projects\Konata` 仓库**唯一持续生效的开发红线**。完整背景见仓外定稿 `D:\Anime-Projects\Konata_v3_重构架构定稿.md`；任何旧仓习惯或过期记忆与本文件冲突时，一律以本文件为准。

---

## 一、18 包单向依赖与零代码生成铁律（硬拦截）

全仓采用 Dart 原生 `Pub Workspaces`，严格执行单向 DAG，由 `dart run tool/verify.dart guard` 在 1 秒内硬拦截：

```text
apps/konata (薄壳组装根)
  ├── packages/features/*        (11 个纵向自治切片，严禁 feature 之间横向互引)
  ├── packages/engines/*         (4 个无 UI 纯 Dart 引擎：engine_cloud_drives / engine_sources / engine_scraping / engine_playback)
  └── packages/foundation/*      (3 个受保护底座：konata_contracts / konata_storage / konata_design_system)
```

1. **唯一公开出口**：跨包只允许导入 `package:<pkg>/<pkg>.dart`，**严禁跨包导入任何 `package:<pkg>/src/...`**。
2. **零框架污染**：
   - `packages/foundation/konata_contracts`、`konata_storage` 与全部 `packages/engines/*` **严格 0 Flutter 依赖**（禁导 `package:flutter/*` 与 `dart:ui`）；
   - `packages/foundation/konata_design_system` **严格 0 Riverpod、0 业务依赖**；
   - `packages/features/*` 业务界面仅依赖 `package:flutter/widgets.dart` 与 `konata_design_system`，禁止直接依赖 `material.dart` / `material_ui` / `cupertino_ui`；
   - 引擎、状态机、控制器与 DAO 均为 **0 `Ref` 纯 Dart 类**（构造函数注入），`flutter_riverpod` 仅允许出现在 Feature 外层的 `providers.dart` 薄胶水、`manifest.dart` 注册清单与 `ui/` 界面层；`lib/src/state/`、`lib/src/data/` 与 `lib/src/domain/` 一律禁止引入（其中 `state/` 与 `data/` 由 `verify.dart guard` 硬拦截）。
3. **全仓零 `build_runner`**：严禁引入 `drift_dev`、`freezed`、`json_serializable`、`riverpod_generator` 与任何 `.g.dart` / `.freezed.dart` 生成物；数据持久化统一使用纯 `sqlite3` + `KonataSqliteEngine`（三库分治：`library.db`、`user_state.db`、`cache.db`），模型与状态机统一使用纯 Dart 3 `sealed class` / `final class` / `Record`。
4. **跨模块唯一 3 条合法通道**：`AppNavigator`（只传 ID）、`DomainEventBus`（低频 `sealed` 事件）、`konata_contracts` 只读 Query 端口；一切跨包能力挂载均走 7 大声明式扩展点（`FeatureManifest` 按字母序显式注册于 `apps/konata`）。

---

## 二、核心业务与三端安全红线

1. **Windows 纯绿色便携**：数据、配置与缓存严格落盘于可执行文件同级目录（调试期为项目目录），**严禁向 C 盘 `%APPDATA%` / `%LOCALAPPDATA%` / `%TEMP%` 写入业务文件**；敏感凭据（密码、Token）仅入本机安全存储，严禁落 SQLite 或进同步。
2. **Android 零桌面残留与三端同源视觉**：Android Release 入口（`lib/main_android.dart`）零桌面插件依赖；Windows 桌面、Android 平板（`shortestSide >= 600dp` 左侧紧凑悬浮胶囊）与 Android 手机（`< 600dp` 底部紧凑悬浮胶囊）共享 `konata_design_system` 唯一视觉体系，禁止另设主题或 Material 换皮；统一采用可拖拽音视频悬浮小窗与公共安全区避让。
3. **媒体源严格只读**：对 Local / WebDAV / SMB 保持只读，删除或合并作品绝不删用户物理媒体文件；Scan 扫图遵守按源并发上限（Local 4 / SMB 2 / WebDAV 严格串行 1 + LIFO），原图零落盘。
4. **三大核心护城河零简化**：严禁为压缩行数删减 `engine_scraping` 任何解析、合集拆分、集号提取或匹配打分规则；`engine_playback` 保留 `libmpv` 零拷贝渲染、四维代数隔离、Hi10P 软解兜底、内存直注字幕与发烧音频 `-12 dBFS` 安全链。
5. **只读保护旧仓**：`D:\Codex-Projects\Konata`（基线 `4ee643f`）永久只读，严禁任何写操作。

---

## 三、开发规范、性能红线与注释洁癖

1. **高频路径零损耗（严禁借总线传输）**：
   - `DomainEventBus` 与 `TableChangeBus` **只承载低频业务事件**；
   - `> 5Hz` 的播放进度、歌词逐字扫白、悬浮小窗拖拽坐标必须直连叶子 `ValueNotifier` / `ref.select`，并在静止/隐藏时退订保持零重绘、零常驻动画 Ticker；
   - 严禁创建无意义单行空转发包装层；`cache.db` 与大词表必须惰性加载。
2. **体量软约束**：不设机械行数硬拦截；普通 UI/业务单文件超过 800 行或内部依赖扇出超过 18 时给出柔和提醒，按自然子职责拆分即可（算法/词表免检）。
3. **配置与同步自治**：每个 Feature 自主定义 `TypedPrefsSlice` 存入 `ScopedPrefsStore`（标明 `portable` 或 `deviceLocal`）；作品艺术图统一用 `ArtworkRef`（远程来源同步引用与锁定态，本地自定义图不泄漏路径且远端回退默认源）。
4. **纯中文功能性注释与文档极简**：
   - 新增与修改文件统一 UTF-8 无 BOM；所有源码注释、输出与沟通均为**简体中文**，仅解释职责、非直观规则与算法原理；严禁英文注释、`TODO`、历史变更记录与注释死代码；
   - 除各包 `PACKAGE.md` 与明确授权外，**严禁在仓内新建方案、进度或总结 `.md` 文件**；旧代码替换后同轮彻底删除。
5. **实测择优**：核心性能优化必须以目标设备预热后连续 5 次采样中位数为依据，无实质改善或负优化必须回退；严禁删有效断言或加忽略注解绕过门禁。

---

## 四、多 Worktree 与开发协同纪律

1. **车道隔离**：并行开发使用 `scripts/lane_manager.ps1` 在 `D:\Anime-Projects\Konata-lanes\<lane>` 创建短命车道，自动生成私有 `.git/konata-lane.json` 写权限白名单（不入 Git），`verify.dart guard` 自动拦截越界修改。
2. **Contract-First 底座保护**：`packages/foundation/*` 默认对业务车道只读；确需改契约时先走短分支合入 `main`，业务车道执行 `git rebase main` 后继续。
3. **自治文档**：废弃单一全局 `SHARED_ASSETS.md`，每个包维护自身简短 `PACKAGE.md`（导出符号、依赖与关键契约）。
4. **硬件互斥**：触及真机压测统一经 `scripts/lane_manager.ps1 -Action lock-verify` 排队。

---

## 五、固定门禁命令表（纯直调，勿外包脚本块）

| 命令 | 职责与预期耗时 | 使用时机 |
| :--- | :--- | :--- |
| `dart run tool/verify.dart guard` | 跨包 DAG、内部路径、禁用依赖与车道白名单硬拦截（~1 秒） | 每次提交前必跑 |
| `dart run tool/verify.dart changed` | 仅对当前改动及受影响包跑 `guard + analyze + test`（10~25 秒） | 日常高频迭代 |
| `dart run tool/verify.dart analyze [包路径]` | 静态分析全仓或指定包（0 error / 0 warning / 0 info） | 按需快速核验 |
| `dart run tool/verify.dart test [包或测试路径]` | 纯 Dart 包走 `dart test`，Flutter 包走 `flutter test` | 模块验证 |
| `dart run tool/verify.dart build` | 在 `apps/konata` 执行 Windows Debug 构建校验 | 原生/入口改动后 |
| `dart run tool/verify.dart all` | 串行执行 `guard -> analyze -> test -> build`（完成后提示音） | 阶段合入与最终交付 |
| `pwsh -NoProfile -File scripts/check_comments.ps1` | 校验全仓纯中文功能性注释与死代码清理 | 合入 `main` 前 |
