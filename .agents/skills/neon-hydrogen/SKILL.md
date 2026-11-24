---
name: neon-hydrogen
description: >-
  使用 Gemini 4 Neon（或 Orchestrator Neon）作为总指挥（Coordinator），编排并指挥
  Gemini 4 Hydrogen Worker 团队在 Konata v3 多包架构下执行并行开发、迁移、Bug 修复与独立测试验收的
  Swarm 工作流。当进入 Phase 2~4 关键并行节点、任务涉及 2 个及以上无交叉独立包、复杂攻坚需要写审分离，
  或用户提到“neon-hydrogen”/“并行开发”时由顶层主会话主动激活（严禁 Worker 套娃激活）。
---

# Neon 指挥 Hydrogen 多包并行工作流（Konata v3）

本技能将当前主会话（**Gemini 4 Neon** 或 **Orchestrator (Neon)**）定义为架构师与总指挥（`coordinator`），通过内置 `swarm` 工具调度 **Gemini 4 Hydrogen** Worker 团队按 17 包物理边界并行编码与独立验收。

## 1. 触发边界与前置准备（必做）

0. **自动触发与防套娃原则**：仅顶层主会话（Coordinator）在满足 `AGENTS.md` 第四节第 5 条（Phase 2~4 节点、≥ 2 个无交叉独立包、高风险攻坚需写审分离）时主动激活本技能；Phase 0/1 底座、Phase 5 真机压测与轻量单点改动保持单人串行；**Swarm Worker 严禁套娃重复拉起团队**。
1. **加载面板技能**：首次启动 Swarm 前，读取内置 `swarm_pane` 技能的 `SKILL.md`，遵守消息板（`post_message` / `read_board` / `swarm_wait`）与 `@mention` 唤醒规则。
2. **核对可用模型与配额**：调用 `swarm{action: "models", all: true}` 核对 Neon / Hydrogen 模型可用性与剩余配额。
3. **确认底座已就绪**：多包并行阶段开始前，确保 `packages/foundation/*` 底座契约已合入 `main` 且 `dart run tool/verify.dart guard` 全绿。

---

## 2. 角色分工与模型固定矩阵

添加编码与验证 Worker 时，**必须在 `swarm{action: "add"}` 中显式传入 `model` 参数**：

| 角色 | 职责边界 | 指定模型 ID | `workspace` 策略 |
| :--- | :--- | :--- | :--- |
| **Coordinator（你 / Neon）** | 需求拆解、契约审查、按包切分无重叠边界、派单、分支合入主干、冲突裁决与向用户汇报。**不亲自编写大段业务代码或跑耗时构建。** | 当前主会话（`gemini-4-neon-xhigh` / `gemini-4-neon-high` / `gemini-pro-orchestrator-neon`） | 主工作区（`main`） |
| **Author Worker（全量编码/攻坚）** | 负责分配包的架构实现、迁移、复杂算法、并发状态机与本包单元测试。 | `gemini-4-hydrogen-xhigh` | 单人改码用 `inherit`；多人并行改码必须用 `share` |
| **Verifier Worker（独立验收）** | **只读审查** Diff、运行 `dart run tool/verify.dart guard` / `changed` / `check_comments.ps1`、核验 `AGENTS.md` 与 `PACKAGE.md`。发现问题直接 `@author` 退回，**绝不自己改码**。 | `gemini-4-hydrogen-xhigh` | `inherit` |
| **配额降级兜底** | 仅当某 Worker 触发配额耗尽时无损切模型续跑（优先 `high`，次选 `medium`），严禁 `kill` 重建。 | `gemini-4-hydrogen-high` | 保持原工作区 |

---

## 3. 标准编排流程（结合 Konata v3 多包边界）

### 第一步：按包切分无重叠所有权
1. 优先按 17 包目录直接划界（每名编码 Worker 独占自己的 `packages/engines/<pkg>/` 或 `packages/features/<pkg>/`），**天然零文件交叉**。
2. `packages/foundation/*` 默认对业务 Worker 只读；若某 Worker 发现缺契约接口，必须立刻 `@coordinator` 上报，由 Neon 走短分支合入 `main` 后再通知各 Worker 同步。
3. 设置面板标题：`swarm{action: "title", title: "<简短中文任务标题>"}`。

### 第二步：编写自包含中文 Brief 并一次性拉起团队
Worker 看不到主会话历史，每条 `brief` 必须完整包含五要素：
1. **包与文件所有权**：明确列出允许读写目录（如 `packages/engines/engine_scraping/`）及严禁触碰目录（含只读旧仓 `D:\Codex-Projects\Konata`）；
2. **权威参考基线**：明确写明只读旧仓基线为 `D:\Codex-Projects\Konata`（commit `4ee643f`）与仓外定稿 `D:\Anime-Projects\Konata_v3_重构架构定稿.md`；
3. **项目强制规范**：要求动手前阅读根目录 `AGENTS.md` 与相关包 `PACKAGE.md`，并按需读取对应技能：
   - 刮削 / 解析 / 匹配 → `.agents/skills/konata-scraper-benchmark/SKILL.md`
   - 设计系统 / 布局 / 浮层 → `.agents/skills/konata-ui-design-system/SKILL.md`
   - 打包 / 签名发布 → `.agents/skills/konata-release-workflow/SKILL.md`
4. **验证标准**：要求编码 Worker 完成后先自跑 `dart run tool/verify.dart guard`、本包测试（纯 Dart 包跑 `dart test`，Flutter 包跑 `flutter test`）与 `pwsh -NoProfile -File scripts/check_comments.ps1`，再同步更新本包 `PACKAGE.md`；
5. **完成流转**：编码 Worker 完成后直接 `@verifier` 附改动摘要与实测命令结果；`@verifier` 通过后再 `@coordinator` 汇报。

### 第三步：巡检、合入与收尾
1. 使用 `swarm_wait` 等待唤醒，按消息序号审阅进展。
2. 当 `workspace: "share"` 的编码 Worker 经 `@verifier` 验收通过后，由 Neon 将其改动按顺序合入主仓 `main`，在主仓复跑 `dart run tool/verify.dart changed` 或 `all` 确认全绿。
3. 确认合入无误并落盘后再对已结束 Worker 执行 `kill`（切勿把 `kill` 当暂停用，`waiting` 态零开销）。
4. 全部验收通过后，向用户输出简洁中文汇报与关键文件链接。
