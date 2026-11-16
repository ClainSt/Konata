# Konata 全局开发宪章 (AGENTS.md)

本文件是 Konata 仓库**唯一持续生效的最高开发准则**，适用于所有 AI Agent（Antigravity / Codex / Claude Code / Cursor 等）执行的功能开发、Bug 修复、重构与构建任务。若仓库内任何旧注释或历史文档与本文件冲突，**一律以本文件与当前生效代码为准**。

---

## 零、Agent 每次任务强制工作流（SOP · 最高优先级）

所有 Agent 接手任何编码或修改任务时，必须严格按以下 4 步闭环执行，严禁跳步：

1. **Step 1 · 先检索，后编码（Search Before Write）**：
   - 写任何 UI 组件前，必须先检索 `lib/presentation/widgets/`（及公共组件目录）与 `lib/presentation/theme/`；写任何工具/解析/格式化逻辑前，必须先全文检索 `lib/domain/` 与 `lib/infrastructure/`。
   - **已有可复用实现时必须直接调用或通过可选参数扩展，严禁在当前文件另起炉灶重复实现**。
2. **Step 2 · 零硬编码与严守分层（Zero Hardcoding & Clean Layers）**：
   - 严禁在业务与界面代码中直接硬编码颜色、圆角、间距、模糊度、动画时长、文件路径、超时时间或默认 URL；所有可配置项与视觉常量必须收口至统一配置类或 Theme Token。
   - 严格遵守 `presentation -> application -> domain <- infrastructure` 单向依赖，全链路使用强类型模型，严禁跨层传递 `Map<String, dynamic>` / `Map<String, Object?>`，严禁新建全局可变静态单例（统一由 Riverpod 托管）。
3. **Step 3 · 废弃代码与过期文档同轮连根清理（Atomic Cleanup）**：
   - 当修改方案、替换组件或重构逻辑时，必须在**同一轮提交内**全局检索旧符号引用，**彻底删除不再被调用的旧函数、废弃类、无用 Provider、孤儿文件、注释掉的旧代码块以及失效测试**（Git 已保留历史，严禁以“留作备份”为由保留死代码）。
   - **严禁新建任何方案、设计、进度、总结类 `.md` 文档**；若本次修改使既有文档过期，必须当场删除过期文档或同步更新本 `AGENTS.md`。
4. **Step 4 · 沙箱职责分流与固定前缀门禁（Zero-Prompt Verification）**：
   - **沙箱职责分流**：只读文件检索、代码查阅及 `git status` / `git diff` / `git log` 一律留在默认沙箱内静默运行，严禁为此申请非沙箱权限。
   - **纯直调固定前缀铁律（命中 Always Allow 白名单）**：执行构建、依赖解析与测试验证时申请非沙箱权限（避免外部 `D:\FlutterSDK` 锁文件与工具链权限受限），但**严禁在命令行外层包裹 PowerShell 脚本块、`$变量`、`$(...)`、分号 `;` 或管道 `|`**，且严禁引用已废弃的 `Anime\.flutter-sdk-cache` 路径。
   - **统一使用以下固定纯直调命令前缀**（超时熔断与子树清理已内置于 `tool/verify.dart`）：
     - `dart run tool/verify.dart analyze`（90 秒超时）
     - `dart run tool/verify.dart test [目标路径]`（180 秒超时）
     - `dart run tool/verify.dart build`（240 秒超时）
     - `dart run tool/verify.dart all`（串行执行并触发提示音）
   - 阶段性开发过程中仅按需运行 `analyze` 或定向 `test`，最终交付阶段再集中运行一次 `all`。
   - 每完成一个大阶段汇报或遇到阻塞需人工介入时，在默认沙箱内执行轻量提示音：`powershell -NoProfile -Command "[console]::beep(880,300)"`。

---

## 一、工程洁癖五大铁律（强制）

### 1. UI 组件与交互样式强制唯一化（Single UI Kit）
- 全站同类 UI 元素**只能存在唯一一套标准组件**，统一收口于公共组件层：
  - **浮层容器**：毛玻璃弹窗（`Dialog`）、侧滑抽屉（`SideSheet`）、底部/右上弹出菜单、悬浮胶囊 `Toast`；
  - **表单与选择**：圆角毛玻璃下拉框（`KonataDropdown`）、可搜索下拉框（`KonataSearchableSelect`）、无粗框输入框、分段胶囊切换器（Segmented Capsule）；
  - **基础交互**：显式绑定独立 `ScrollController` 的可拖拽滚动条、自动检测单行截断并悬停展示全称的 `Tooltip` 文本组件、统一来源/分辨率/编码规格角标组件、音视频底部居中播控胶囊。
- **禁止行为**：严禁在单个页面或弹窗内手写私有的毛玻璃容器、私有下拉框、原生直角 `DropdownButton`、Material 默认天蓝按钮、底部黑条 `SnackBar` 或纯黑实心弹窗。

### 2. 彻底根除硬编码（Centralized Tokens & Configs）
- **视觉 Token 集中管理（`lib/presentation/theme/`）**：
  - 品牌色与角标色（如 Bangumi 粉、TMDB 深蓝渐变、分辨率白底黑字）、深浅主题表面色/文字色/边框透明度、圆角半径、毛玻璃模糊 sigma、标准间距、标准过渡时长（如 `200ms`）与曲线，必须引用全局 Theme Token；除 `Colors.transparent` 外，业务 Widget 内禁止散落裸 `Color(0x...)` 与魔法数字。
- **存储路径集中管理（`StorageRootProvider` / 统一路径服务）**：
  - 所有本地持久化文件（数据库、配置快照、`mpv` 沙箱目录、`photos/` 图片目录）必须由统一路径服务生成：
    - **Windows 桌面端（纯绿色便携模式）**：严格基于 `File(Platform.resolvedExecutable).parent`（调试模式指向项目根目录并加入 `.gitignore`），**严禁向 C 盘 `%APPDATA%`、`%LOCALAPPDATA%` 或系统 `%TEMP%` 写入任何图片或运行缓存**。
    - **Android 端（预留跨端一致接口）**：统一映射至应用专属 `ApplicationSupportDirectory`，上层业务代码零平台路径分支。
  - **作品图片唯一目录规范**：`<Root>/photos/<过滤非法字符的作品名> [<workId>]/` 下按需创建 `posters/`、`backdrops/`、`logos/`、`thumbnails/`、`scans/` 五类子文件夹（无文件不建空目录；作品删除、改名或合并时必须同步清理/迁移对应作品文件夹）。
- **业务与网络常量集中管理**：
  - 默认官方与备用 API/图片镜像地址、网络超时、缓冲区大小、WebDAV `Scan` 串行并发数（固定为 `1`）、微缩图目标尺寸（如 `360px` WebP）必须定义在具名配置常量类中，禁止散落在调用处。

### 3. 杜绝重复逻辑实现（DRY & 严禁私有跨页工具函数）
- **禁止在 UI 文件内编写通用处理函数**：凡涉及文件字节大小格式化、时长/时间戳格式化、路径清洗与父子目录提取、自然排序、BDRip 文件名/集号/特典/CD/Scan 分类解析、`.cue`/`.lrc` 解析、音轨/字幕优先级匹配等逻辑，**一律下沉至 `lib/domain/`（或无状态公共工具类）**，严禁在某个 Page 或 Dialog 内写私有的 `_formatBytes`、`_extractSubDir` 等局部函数。
- 新增或复用通用函数时，必须保证全仓**同一职责只有唯一一份实现**，并配有对应单元测试。

### 4. 零冗余代码残留（Zero Dead Code）
- 迭代替换任意特性后，交付前必须自检并确保：
  - 无任何未被外部引用的类、方法、枚举值、Riverpod Provider 或孤儿 `.dart` 文件；
  - 无大段被 `//` 或 `/* */` 注释保留的旧版实现代码；
  - 无不再使用的第三方 `pubspec.yaml` 依赖包或废弃原生构建源文件。

### 5. 文档极简主义与防过期治理（Code as Single Source of Truth）
- **严禁文档泛滥**：除非用户在当前对话中明确下令创建指定文档，否则 Agent **绝对禁止**在仓库根目录或 `docs/` 下新建任何方案书、设计草稿、重构记录、审计报告、退役说明或阶段总结 `.md` 文件（分析报告与改动清单仅在对话消息中直接输出）。
- **过期即删**：仓库内仅保留 `AGENTS.md`（面向开发与 Agent）与必要的 `README.md`。一旦架构演进导致旧文档与当前代码不符，必须立即删除旧文档并同步修订 `AGENTS.md`，绝不允许过期文档留在仓库中误导后续上下文。

---

## 二、产品定位与核心业务边界（强制）

1. **跨平台二次元媒体库管理（Windows 优先 + Android 架构对齐）**：
   - 专注简体中文（`zh_CN`），不设多语言切换与冗余翻译表；不设声优/角色资料墙与插件扩展商店，不留未实装的空白占位按钮。
   - **媒体源严格只读安全**：对本地磁盘、WebDAV（Basic / Digest）、SMB 媒体源保持严格只读（仅用户主动执行目录重命名追加标签时例外）；删除或合并作品仅操作本地数据库与 `photos/` 缓存，**绝不删除用户物理媒体文件**。
2. **双模音视频播放引擎 + 内置跨端画册查看器**：
   - **视频与 CD 音频（内置主力 + 外部备选）**：
     - 默认采用内置 `libmpv` 统一内核（复用本地经 `manifest.json` SHA-256 校验的运行时，视频走物理像素级 Flutter `Texture` / D3D11 共享纹理合成以 100% 兼容毛玻璃浮层，CD 音频走独立保活的 `vid=no` 纯音频实例驱动「迷你底栏 ↔ 全屏流光倒影页」）；
     - 完整保留外部播放器（MPV JSON IPC / PotPlayer Win32 消息 / 自定义外部音频与看图程序）作为设置页全局备选与右键/播控栏单次快捷唤起通道，支持携带当前时间戳无缝热接力；
     - 远程 WebDAV / SMB 资源统一经由本地 `127.0.0.1` `LocalStreamBridge`（支持 HTTP `206 Range`、`If-Range` 与重定向凭据隔离）流式透传，原文件零落盘。
   - **Scan 扫图（分源调度 + 原图零落盘）**：
     - 本地源受控并发生成微缩图，WebDAV 源严格执行**单连接串行队列（并发 = 1）**并在切页时立即取消未完成请求，仅将轻量 `360px` WebP 微缩图落盘至作品 `scans/` 目录；内置查看器浏览大图时仅在内存保留少量预读纹理（开启 `FilterQuality.medium` 抗锯齿），严禁将数 MB 原始扫图落盘。

---

## 三、四层架构与公共能力定址表（防重复检索索引）

严格执行单向依赖：`presentation` -> `application` -> `domain` <- `infrastructure`。开发前按此表定址复用：

| 层级与目录 | 唯一职责边界 | 严禁出现的违规行为 |
| :--- | :--- | :--- |
| **`lib/domain/`**<br>纯领域核心层 | 实体与值对象、BDRip 文件名与技术规格解析、目录树聚合、`MultiWorkSplitter` 合集拆分、15 级集号提取、特典/CD/Scan 二级分类与多版本归组判定、候选打分（`WorkMatcher`）、轨道偏好（`TrackPreferences`）、观看区间追踪（`WatchedTracker`）、通用纯文本/字节/时长格式化、仓储与播放接口定义 | 严禁导入 Flutter UI、`drift`、`http`、`dart:io` 真实文件 I/O 或原生插件 |
| **`lib/application/`**<br>应用编排层 | Riverpod Notifier/Provider 状态编排、四段式刮削漏斗调度、作品合并/迁移编排、视频播放控制器与全局保活纯音频控制器、设置偏好同步。CPU 密集型解析打分与本地图片裁剪/降采样必须放入后台 `Isolate` | 严禁直接拼装 Widget 或写底层 SQL / HTTP 细节；严禁阻塞主 UI Isolate |
| **`lib/infrastructure/`**<br>基础设施层 | Drift (SQLite) 实现、TMDB + Bangumi 双源协同网络客户端（内置 DoH + TLS SNI / 代理 / 自定义镜像）、Local/WebDAV/SMB 只读网关、`LocalStreamBridge` 流网桥、内置 `libmpv` 会话与 `mpv_quality_profile` 容错参数中心、外部播放器 IPC/Win32 追踪器、`StorageRootProvider` 与 `photos/` 作品图片及 Scan 微缩图缓存管理 | 严禁反向引用 `application/` 或 `presentation/` |
| **`lib/presentation/`**<br>界面表现层 | `theme/`（全局颜色、圆角、毛玻璃、动效 Token 与窗口材质控制器）、`widgets/`（全站唯一共享毛玻璃弹窗/抽屉/下拉框/滚动条/角标/Tooltip/播控胶囊组件库）、各业务页面与视图 | 严禁在 Widget 中直接发起数据库读写、网络请求、文件/进程 I/O 或内联通用解析算法 |

---

## 四、代码体量分层控制与刮削 100% 保真

1. **刮削、解析与匹配核心算法（`lib/domain/`、`lib/application/scraping/`）—— 业务保真绝对优先**：
   - **严禁为了压缩行数而简化、合并或删减任何目录分析、合集拆分、集号提取、特典限定词（如 `Character PV` vs `PV`）识别、季级元数据身份或匹配打分规则**。
   - 允许核心规则与词表保持单文件高内聚；仅当单文件超过 `1800~2000` 行时，按自然子职责或 `part` / `part of` 进行无损物理拆分。
2. **UI 视图、应用控制器与基础设施（`lib/presentation/`、`lib/application/`、`lib/infrastructure/`）—— 模块化精简控制**：
   - 新增与重构文件日常保持在 400 ~ 900 行，以 1000 ~ 1200 行为软性拆分参考线；超过时必须按独立子面板、弹窗或子服务拆解，杜绝巨型上帝组件。

---

## 五、视觉与交互一致性规范（强制）

1. **桌面透光材质与顶栏保活**：
   - 基于 `flutter_acrylic` + `window_manager` 支持亚克力（Acrylic）/ 云母（Mica）与深浅主题；常规管理页根 `Scaffold` 保持 `Colors.transparent`（内置视频页底层铺纯黑画布防透底，不反复切换 DWM 材质防黑闪），每次应用材质后必须确保 `Window.hideWindowControls()` 生效，杜绝双套窗口按钮。
   - 顶栏左侧纯文字排布 `媒体库 | 媒体源 | 播放记录 | 设置`（采用隐形粗体层自然撑宽防缺字抖动，四主页面首次访问懒加载后常驻保活 + 平滑淡入位移过渡）。
2. **全站可拖拽滚动条与防溢出对齐**：
   - 全站所有滚动视图（含弹窗、侧边抽屉、下拉菜单）必须开启 `interactive: true` 并为 `Scrollbar` 与内部滚动组件绑定**同一个显式 `ScrollController`**，预留右侧安全内边距防滚动条压边。
   - 双栏并排卡片保持结构对称或自适应高度，严禁写死固定高度或误用 `IntrinsicHeight` 触发 `BOTTOM OVERFLOWED` 溢出。
3. **沉浸式详情页与统一播控胶囊**：
   - 详情页支持 `正片 | 特典 | CD | Scan`（受设置页显示开关实时控制）及动态半透明毛玻璃二级分类筛选；右上角固定常驻 `[ ⊞ < > ⌄ ⚙ ]` 导航胶囊（完整列表按钮始终固定于此，不随二级分类跳动）。
   - 内置视频页与音频页共用同源几何比例的**底部居中悬浮毛玻璃控制胶囊**，互不冲突。

---

## 六、交付前强制门禁清单（Definition of Done）

每次任务结束向用户汇报前，必须逐项核验并 100% 通过：
1. **复用与洁癖自检**：未重复造公共组件/工具函数、无新增硬编码魔法值、本次替换掉的旧代码/孤儿文件与过期文档已全部删除。
2. **统一门禁全量通过（`dart run tool/verify.dart all`）**：使用固定纯直调命令前缀在非沙箱前台运行，确保以下三段全部通过：
   - **`analyze`**：结果必须为 `No issues found!`（0 error / 0 warning / 0 info）；
   - **`test`**：全量单测、刮削基准回归测试与新增逻辑测试 100% 通过；
   - **`build`**：`flutter build windows --debug` 原生 CMake 校验与链接编译通过。