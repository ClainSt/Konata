# Konata 项目级全局开发规则

本文件中的规则适用于 Konata 项目今后的所有功能开发、Bug 修复、重构、依赖升级以及 Windows/Android 构建，是持续生效的强制开发约束，而不是一次性的优化建议。

## 产品定位与核心边界（强制）

Konata 的目标是轻量级个人媒体库与内置播放器。核心应用应完整提供：

- 媒体库管理、海报墙与基础元数据刮削；
- 以忠实还原源视频画面为目标的内置播放器，以及必要的音轨、字幕和播放控制；
- 基础播放记录与断点续播；
- 基础备份与恢复，覆盖媒体库、播放记录及必要设置。

轻量级是基础约束，但不得以裁剪核心解码、字幕、色彩处理或稳定性换取体积。画面还原应依据源文件和设备能力，分别验证 Windows 与 Android 的实际输出；不能仅凭支持某种格式、启用某个选项或显示设备位深宣称已经达成。

### 内置可选功能与资源生命周期（强制）

- 停止开发应用扩展插件、插件市场和脚本运行器。增强能力采用内置可选功能，复用现有 Flutter、Dart 与原生能力，不为功能开关建立通用插件框架。
- 设置中的“扩展”位于“关于”正上方，仅提供“Bangumi角色/声优资料”和“TMDB真人资料”两个开关。刮削服务中提供“角色栏”总开关，开启后才显示 Bangumi 的角色 / 声优 / 关闭选项。动画优先使用已开启的 Bangumi 展示；Bangumi 关闭时若 TMDB 开启则使用 TMDB，否则隐藏角色栏。新配置默认启用 Bangumi 角色，保留已有明确关闭的偏好。
- 功能开启后，其详细设置才出现在所属分类（例如角色声优、真人演员属于“刮削服务”）；关闭后撤下相关设置与功能界面。
- 默认关闭的功能不得创建业务服务、发起网络请求、加载图片、运行定时器或注册业务监听。只有启用且实际使用时才按需初始化。
- 关闭时停止新任务，取消或安全结束已有任务，撤销监听和计时器，释放功能独占的网络连接、图片、缓存、解码器等资源；防止已取消结果重新进入界面或缓存。
- 扩展统一由 `OptionalFeatures` 管理启停，使用共享 `OptionalFeatureScope` 登记、取消及释放独占资源；各功能只实现业务逻辑，不重复实现开关监听、请求取消、定时器和资源生命周期。新增功能必须接入该管理层。
- 关闭不删除用户自定义资料、记录和设置。共享资源按使用者管理，不能为了停用扩展破坏核心功能。
- “关闭时不占资源”的验收含义是无持续业务活动、独占资源可回收、反复开关不累积；不能宣称安装包中的代码、共享运行库或进程内存绝对归零。
- 验证始终关闭、开启后关闭、反复启停和重启四种场景，Windows 与 Android 分别验收。明显占用变化须测量；未实测的 CPU/GPU、电量、系统内存必须明确标注。
- 大型资源仍按需下载并限制容量；不得因内置可选化默认捆绑大型素材、字体或数据库。
- 迁移已有插件功能时保留用户资料和回退文件；已知官方插件的启用状态及展示偏好可迁移，旧脚本不再执行。

每项新增功能实施前，先说明属于核心能力还是内置可选功能，再执行成本评估与验收。上述是持续生效的产品目标，不代表所有功能和资源指标均已验证。

## 体积、性能与维护成本（强制）

### 1. 每项新功能都必须评估成本

任何新功能、依赖或架构调整，在实施前必须评估：

- 对 Windows 和 Android 安装包大小的影响；
- 对安装后磁盘空间的影响；
- 对运行时内存、CPU、GPU 和电量的影响；
- 对缓存和长期存储占用的影响；
- 对源码复杂度、可读性和后续维护的影响；
- 对双端兼容性和测试工作量的影响。

不能只考虑功能能否实现。

### 2. 保持源码简洁实用

- 优先使用现有成熟代码和框架能力。
- 不重复实现 MPV、Flutter 或操作系统已提供的功能。
- 面对非平凡问题（如格式解析、匹配算法、并发调度、缓存策略、协议处理或典型 UI 交互），先调研主流开源方案与社区避坑经验，避免闭门造车与重复造轮子：在许可证兼容、双端可用且不违反安装包体积、性能与只读边界的前提下优先直接复用；若不宜直接引入依赖，则“取其精华、去其糟粕”，提炼其核心算法模型、分层设计与边缘测试用例，用轻量代码落地，同时不为简单逻辑盲目堆叠重型依赖。
- 避免过度封装、无意义抽象、重复状态管理和重复代码。
- 不为了追求设计模式而增加不必要的文件、类或依赖。
- 及时移除确认无用的遗留实现，但必须先验证没有引用。
- 不因单纯减少代码行数而降低可读性和可维护性。
- 尽可能减少对第三方依赖源码的直接修改，必要补丁须有明确说明及回归测试。

### 3. 严格控制安装包体积

- 优先使用系统字体、系统接口和已有原生能力。
- 不默认打包无必要的字体合集、测试视频、大型离线数据库、脚本合集及着色器合集。
- 高级功能按需启用，大型资源按需下载。
- Android 优先评估 ABI 独立构建。
- Windows 避免重复打包 DLL 和原生运行库。
- 新增依赖前必须确认现有依赖无法合理实现相同功能。
- 不为了极小的体积收益引入高复杂度的维护方案。

### 4. 播放质量优先于极限瘦身

Konata 的核心目标是以较小体积提供接近成熟 MPV 方案的高质量动画 BDRip 播放体验。

不得为了缩小安装包而损害：

- H.264、H.264 Hi10P、HEVC Main10 等核心视频解码能力；
- FLAC、AAC 等常见音频能力；
- ASS/SSA 复杂字幕及内嵌字体支持；
- 正确的 SDR 色彩、必要的 HDR 处理和高质量渲染；
- Windows/Android 的稳定播放；
- WebDAV 原始码流播放及正常缓存。

UI 优先使用系统字体，但不得错误地将字幕专用字体需求视为普通 UI 字体需求。

### 5. 所有缓存必须可控

视频缓存、海报、元数据、日志、缩略图及临时文件应有合理的容量和生命周期管理。

避免无上限增长、重复缓存和不必要的后台下载。

不得自动删除用户自定义资源或媒体库数据。

### 6. 每项功能必须满足验收条件

实施新功能或优化时，必须检查：

1. 是否引入不必要的新依赖；
2. 是否增加明显的安装包或运行时占用；
3. 是否存在更简单、可复用的实现；
4. 是否增加不合理的维护复杂度；
5. 是否影响 Windows/Android 双端兼容；
6. 是否导致播放器质量、性能或稳定性退化；
7. 是否需要补充自动化测试；
8. 是否存在安全可靠的回退方案。

对于体积或性能影响明显的变更，提供优化前后测量结果。

无法量化的项目应说明原因，不能编造优化收益。

### 7. 决策优先级

在功能相同且满足质量要求时，优先选择：

**稳定可靠 → 播放质量正确 → 代码简洁易维护 → 资源占用低 → 安装包小。**

若发现某项优化将显著增加技术债务，或需要牺牲关键播放能力，应停止该方案，并先向用户说明替代选择。

### 平板与可调整窗口

所有 UI 均按当前页面实际可用宽高自适应，不按手机、平板或桌面设备名称锁定排版。窗口缩放、旋转与分屏后须重新布局；已打开的设置二级页也不能固定在打开时的单栏模式。桌面窗口控制、移动端安全区与触控习惯可分别保留。

新增或修改布局时，检查窄窗口、手机横竖屏、平板横竖屏、分屏、宽屏，以及字体放大、长标题与中英文文案。空间不足时调整列数、换行、导航或单/双栏，保持主要操作可见可用，避免溢出、遮挡及要求重复点击。网格完整行应均分可用宽度，不因缩小卡片而固定留下右侧空带；最后一行项目不足时保持正常卡片尺寸。

详情页按实际可用宽高决定是否显示背景图。空间充足的 Android 横屏平板与 Windows 采用相同背景；手机横竖屏或分屏空间不足时省略背景图及其加载。

### 发布目录

Windows 便携目录、ZIP 和 Android APK 统一交付到项目 release 目录。确认两端产物正确并更新 latest-build.json 后，再清理旧发布包和对应便携目录，保留其他文件。

### 分平台播放体验

Windows 和 Android 的播放输出、交互和实机验收分别设计。Windows 优先桌面单窗口、高位深呈现、缩放和键鼠控制；Android 按设备解码、触控、功耗和生命周期单独优化。可共享媒体库与观看记录，避免以跨端实现一致性限制任一端的播放体验。

## Konata Engineering Rules

### Objective

Reduce verified technical debt without introducing regressions.

### Before changes

- Read relevant implementations and all important callers.
- Identify existing behavior, contracts, and compatibility constraints.
- Prefer evidence from source code and runnable tests.
- Do not guess undocumented behavior.

### Refactoring

- Preserve existing observable behavior unless explicitly approved.
- Make one independently testable change at a time.
- Prefer minimal, reversible changes.
- Avoid unnecessary abstractions and new dependencies.
- Do not perform unrelated cleanup.
- Do not silently remove compatibility logic.
- Avoid unrelated file formatting or renaming.

### Validation

- Run relevant tests and build checks.
- Review the final diff for regressions.
- Compare performance only using reproducible benchmarks.
- Never report unexecuted tests as passing.
- Clearly identify unverified assumptions.

### Safety

- Respect the authorized workspace boundary.
- Never overwrite user data or secrets.
- Do not perform destructive Git operations.
- Do not commit or push unless explicitly requested.
- Stop after the requested task and report results.
