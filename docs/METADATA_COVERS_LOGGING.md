# TMDB / Bangumi、封面裁剪与调试日志交付记录

日期：2026-11-05。直接修改现有 CCPlayer；没有修改播放器、WebDAV/SMB 路径语义、媒体源文件或真实用户数据库。本次工作保留在工作区，未提交或推送。

## 已实现的入口与配置

设置 → 元数据与刮削服务：保留原 TMDB 凭证管理入口，新增服务器设置入口。四个地址独立保存到 SharedPreferences（metadata_server_0 至 metadata_server_3），首次使用以下默认值：

| 项目 | 默认值 | 官方预设 |
| --- | --- | --- |
| TMDB API | https://api.tmdb.org/3 | https://api.themoviedb.org/3 |
| TMDB 图片 | https://images.tmdb.org/t/p/ | https://image.tmdb.org/t/p/ |
| Bangumi API | https://api.bangumi.lat/v0 | https://api.bgm.tv/v0 |
| Bangumi 图片 | https://lain.bangumi.lat | https://lain.bgm.tv |

每个提供者分别有“恢复默认”“官方标准地址”。输入框始终显示真实地址；保存时校验并规范化斜杠及版本后缀。禁止 URL 内嵌用户名密码、查询参数、片段、非 HTTP(S) 协议。HTTP 风险在界面说明；带 TMDB 凭证的自定义服务必须使用 HTTPS，并由用户勾选明确授权。不会关闭证书验证。

自动故障回退保存为 metadata_fallback；默认开启，可关闭。自定义 TMDB 凭证授权保存为 metadata_trust_tmdb。原有 Token / API Key 继续保存在系统安全存储，不另建认证体系。[TMDB 认证文档](https://developer.themoviedb.org/docs/authentication-application)。

## 四项连接诊断与正式网络层

- TMDB API：使用现有认证，真实 GET /tv/100565?language=zh-CN，验证 ID、名称与 poster_path。
- TMDB 图片：先取真实详情，再下载 original 海报，检查状态、image Content-Type、文件大小、像素上限和实际解码。
- Bangumi API：真实请求 /subjects/302189 和 /subjects/302189/characters，检查作品及角色字段。角色接口失败显示“部分功能异常”。公开接口不携带登录 Token，统一使用带项目链接的 User-Agent。[Bangumi API](https://bangumi.github.io/api/)。
- Bangumi 图片：下载真实作品封面与角色头像并解码。仅识别已知 Bangumi 图片域名后做映射；保留原路径和查询参数，已是所选镜像时不再次替换。

测试访问输入框内尚未保存的地址，不读缓存、不故障回退。结果显示地址、HTTP 状态、耗时、图片字节数或错误类别；区分认证、超时、TLS、DNS/TCP、HTTP、JSON/图片问题。测试按钮有加载/防重复状态，最近结果在当前应用会话内保留。互不相关的无效地址不会阻止其他服务的独立测试；图片测试需要同提供者 API 返回真实图片路径。

正式客户端统一经过 MetadataHttp：优先当前设置，对网络错误和 5xx 做有限备用请求，401/403/429 不重试；短期记录失败主机，网络失败时使用持久化 JSON 缓存。带凭证请求禁止自动重定向，避免认证外泄。元数据与图片 IO 共用最多 6 个并发名额；请求/响应设置超时与 32 MB 响应上限。JSON 缓存上限约 64 MB，按旧文件淘汰。服务切换不清空缓存或绑定。图片服务器历史前缀使用 metadata_image_history_1 / metadata_image_history_3 持久化，支持自定义路径切换后旧 URL 的安全映射与缓存复用。

## 多条目关联、角色与既有数据保护

数据库由 v12 升至 v13，仅为 works 添加 bangumi_ids、bangumi_link_info、cover_edit_json、character_order 四个可空 TEXT 列。旧 bangumi_id 保持兼容，未改动作品主键、媒体文件或观看历史。

详情页 → 编辑元数据：可以输入多个逗号分隔的 Bangumi ID，例如 302189, 331887。保存为人工确认/锁定的关联集合；自动刮削不能替换它。搜索绑定 Bangumi 时保留已有集合，不生成第二部作品。没有可靠匹配时仍沿用原有待复核流程，不采用搜索第一项。

详情元数据依次抓取所有关联条目，以 Bangumi 角色 ID 去重，不按名字合并；补足缺失图片与名称，合并声优和来源 ID，保存原始排序及声优详情。主角优先、配角其次，同级保留来源的稳定次序。编辑元数据 → 角色排序支持拖动并持久化，手动次序高于自动角色关系排序。部分角色接口失败时保留缓存角色；带 manual 标记的既有角色资料优先保留。详情缓存版本提升为 8，多条目集合进入缓存身份标识。

原有扫描、正篇/特典分类、视频版本、源目录及播放进度逻辑保持原流程。新增日志只记录类型、公共外部 ID 和计数，不输出私有文件名或媒体路径。

## 封面选择、固定比例裁剪与资源保存

详情页 → 编辑封面支持 TMDB、每个关联 Bangumi 条目的封面、本地图片及重新裁剪当前原图。网络候选显示真实预览；加载候选时可取消或直接导入本地图片。TMDB 候选请求 original 原图。

所有候选进入同一个 PosterCropPage。检查原有媒体库组件后沿用 **2:3** 固定比例：图片保持等比，框外遮罩，框内实时显示最终区域。支持鼠标拖动、滚轮、滑块、触摸拖动与双指缩放，缩放范围 1–8。裁剪坐标夹在原图边界内；最小缩放完全覆盖裁剪框。重置居中，取消不写作品状态。

使用 Flutter 原生图像编解码处理 JPEG/PNG/WebP 和平台支持的图像方向，不引入新裁剪依赖。处理前检查字节数和 6400 万像素上限；裁剪工作图最长边最多 4096，导出最多 1000×1500 的 PNG，并按素材实际尺寸限制输出，避免反复有损压缩。低清图显示提示。绘制、解码及编码采用异步引擎操作；不截取 UI 缩略图作为导出。

原始字节和裁剪结果各自按 SHA-256 保存：artwork:original_<hash>.png 与 artwork:crop_<hash>.png。文件中的原图字节保持原格式，资源以解码器识别文件头（原图资源文件扩展名不代表转码）。不修改本地原文件，也不向 WebDAV/SMB 写入。cover_edit_json 记录来源、来源作品 ID、原图资源、输出资源、裁剪矩形与解码尺寸、人工选择状态。重新裁剪读取原图资源；不会再裁上一次 JPEG。

manual_cover_url 使用稳定资源 ID，首页/媒体库/详情页通过 ManagedImage 统一读取并随 Catalog 通知更新。扫描及重新刮削不覆盖该字段；缺少跨设备本地资源时优先回退到提供者海报，不把 Windows 绝对路径用于 Android。现有项目没有跨设备图片同步服务，本次没有额外建立同步系统。

网络图片缓存约 256 MB，按资源路径统一识别已知镜像域名，避免同一尺寸资源换域名重复下载。缓存、原图和裁剪结果分开；清理只处理 cache_ 文件，不删除用户原图/裁剪文件。旧的手工封面版本暂不自动回收，长期大量编辑可能增加资源占用。

## 设置 → 关于 → 调试日志

“启用调试日志”默认关闭，SharedPreferences 的 debug_logs 持久化；切换立即生效，不删除旧日志。关闭时只保留必要 ERROR，停止详细记录。日志带本地时间和时区、等级、模块、事件；记录启动版本/平台、全局异常类型、请求服务器/公共资源类型/状态/耗时、回退、扫描计数、匹配复核、图片/裁剪/缓存异常。

日志使用串行文件写入，约 10 MB 轮转，保留 7 天并限制文件数量约 14；写入失败不会向业务流程抛出。严重要素采用 flush 写入。记录事件时不传入凭证、私有路径或完整 JSON，另集中脱敏 HTTP/SMB/WebDAV URL、Bearer、Authorization、Cookie、API Key、Token、密码与用户名形式的内容。

实际路径采用 getApplicationSupportDirectory()/logs：

- 当前 Windows 安装元信息对应 **C:\Users\clainst\AppData\Roaming\com.clainst\ccplayer\logs**；“打开日志目录”创建真实目录后调用 explorer.exe。
- Android 为应用支持目录的 logs，通常为 **/data/user/0/com.clainst.ccplayer/files/logs**（以设备实际 path_provider 返回值为准）。不能用普通文件管理器直接浏览时，入口列出日志，由 FilePicker.saveFile 通过系统文件选择器导出单个文件，不申请全文件访问权限。空目录仅提示无日志，不伪报导出成功。

## 修改文件清单

已有源码：

- lib/core/catalog.dart：兼容迁移、关联/排序/封面持久化与缓存保护。
- lib/core/metadata.dart、personal_scraper.dart：接入统一客户端，复用认证与图片地址。
- lib/core/detail_metadata.dart：多条目角色和声优合并、缓存版本。
- lib/core/cover_options.dart：多条目真实封面和原始海报。
- lib/core/personal_scrape_coordinator.dart、selected_scanner.dart：脱敏诊断事件。
- lib/main.dart：配置/缓存/日志初始化、异常记录、统一图片加载。
- lib/ui/nipaplay_detail_page.dart：统一图片加载、缺少本地封面的回退。
- lib/ui/settings_page.dart：服务器入口、关于页日志开关与平台日志访问。
- lib/ui/work_edit_dialogs.dart：多 ID 管理、角色排序、候选封面/本地图片/裁剪流程。

新增源码：

- lib/core/metadata_servers.dart、metadata_http.dart、request_budget.dart。
- lib/core/connection_diagnostic.dart、bangumi_links.dart、image_store.dart、debug_log.dart。
- lib/ui/managed_image.dart、metadata_server_settings.dart、poster_crop_page.dart（含独立 Widget Preview）。

测试：新增 metadata_services_test.dart、metadata_migration_test.dart、metadata_live_test.dart；更新 app_shell_test.dart、cover_options_test.dart、detail_metadata_test.dart、personal_scraper_test.dart、season_identity_test.dart、selected_scan_workflow_test.dart 以匹配新入口/域名，角色假数据补上真实 API 必有的 ID。

本任务没有新增第三方依赖。开发期间另一个并行任务新增了 TMDB 归属标识（tmdb_attribution.dart、tmdb_attribution_test.dart、assets/brand/tmdb-logo.*、TMDB.md 与 pubspec 资源声明，并在设置页插入标识）。这些改动已保留；资源配置经离线 pub get 刷新，其作者随后修复了测试定位器类型问题。上述 121 项包括并行新增的 6 项归属标识测试；本任务的实际源码清单不将它们计为本任务新增功能。

## 验证结果与边界

- 完整 Flutter 回归：**121 通过，1 项联网测试默认跳过**。既有扫描、目录、版本、手工绑定、播放进度、WebDAV/SMB 与 UI 测试通过。
- 新增针对性测试：**17 项均随完整回归通过**，覆盖独立设置、URL/认证边界、真实图片解码拒绝 HTML、缓存、角色合并、日志轮转/脱敏/开关、鼠标拖动/滚轮/重置、真实裁剪导出与取消。
- SQLite v12 → v13 真实临时库升级测试通过；验证观看进度、锁定状态、关联集合、跨重启手选封面、缺资源回退和角色手动次序保留。没有迁移真实用户数据库来冒充测试。
- 实际联网 Bangumi 测试单独开启并通过：302189 的角色 30、封面 505233 字节、头像 35805 字节；331887 的角色 28、封面 541420 字节、头像 35805 字节；均解码有效，两组按角色 ID 合并后数量减少。
- Windows release 构建成功：build/windows/x64/runner/Release/ccplayer.exe，运行时应保留同目录的 data/ 与 DLL。
- Android debug 构建成功：build/app/outputs/flutter-apk/app-debug.apk。采用已有 JDK 17 和 Android SDK，没有改全局 JAVA_HOME。
- 静态分析最终 **No issues found**；git diff --check 无补丁错误。
- docs/verification/crop-desktop.png 来自 Flutter 测试渲染器，用于验证裁剪几何与遮罩；测试默认字体不是实际系统中文字库，不能当作原生应用视觉验收。

尚未实测：本轮没有可注入测试进程的真实 TMDB 凭证，未执行带认证的真实 TMDB 100565/图片联网检查；业务校验、401 与图片失败分支通过模拟测试。未进行 Windows 原生窗口中的日志目录点击、原生图片选择器和真实启动/播放回归；未在 Android 真机/模拟器点击文件选择器/导出、双指触摸、横竖屏或播放。不能据构建成功宣称上述交互全部验收通过。未专门导入带 EXIF 旋转的照片做设备级验证；方向处理依赖 Flutter/平台解码器。

## 回滚

提交/发布前可审查本工作区 diff。旧版本程序不认识数据库 v13：实际升级前应备份应用支持目录中的 ccplayer.db（以及 SQLite 的 WAL/SHM，如存在），并保留 artwork 与设置文件。回滚程序时恢复与该程序版本一致的数据库备份；不要直接让旧版程序打开 v13 数据库，也不要通过删库解决版本问题。本轮没有安装 APK、替换已安装程序或升级真实用户库。

默认镜像及 images.tmdb.org 的长期可用性仍取决于外部服务；四项配置、回退及缓存是其可维护保障。构建与详细验证输出见 docs/verification/ 下的文本记录。

## 后续界面修正

元数据服务器弹窗统一为现有设置页的 12px 圆角、21px 标题、15px 输入文字和较轻边框；提供者用独立分区、字段使用上方标签与明确间距。连接状态简短显示，完整诊断放入可展开区域。只保留一条受控细滚动条，内容右侧预留 32px，标题与保存/取消按钮固定，避免滚动遮挡。API/图片测试、保存、预设和回退逻辑保持原功能。

新增 metadata_settings_layout_test.dart：1100×800、640×480、320×640 两种主题共 6 项通过；手机宽度按 1.5 倍字体检查，包含展开诊断后与下一字段的间隔、滚动条避让以及底部按钮可见性。现有 app_shell_test 的 3 项回归通过，静态分析无问题。Windows 与 Android 构建重新生成。未将自动布局测试表述为真机交互验收。

## 刮削服务与 TMDB ID 说明入口

设置侧栏、内容标题、服务器卡片和服务器弹窗统一命名为“刮削服务”。标题右侧新增“TMDB ID 增强识别”帮助按钮，点击打开独立说明弹窗，关闭后回到原设置页；窄屏时入口换行。说明根据 Catalog.tmdbId 的真实规则列出带括号的标记格式，推荐将 ID 放在作品文件夹，提供《86》目录示例、扫描及手工绑定操作、季集和网络限制，不承诺 100% 自动匹配。

新增 tmdb_id_guide.dart 与 tmdb_id_guide_test.dart；说明入口、手机放大字体、关闭返回，以及原设置页/服务器布局共 11 项测试通过。

## 手机端布局与设置导航修正

手机媒体库固定三列，保留 2:3 海报比例；标题高度随系统字体缩放。应用手机壳层统一使用顶部 SafeArea 和主题背景，防止媒体库、媒体源等工具栏进入状态栏区域。底部导航将设置作为真实第三标签，使用 IndexedStack 保留页面状态；重复点击设置不会再叠加弹窗，根设置页按系统返回键回到媒体库。

手机刮削服务、TMDB 凭证、ID 说明使用 MaterialPageRoute 和全屏 Scaffold，系统返回逐级回退。桌面仍沿用现有弹窗。SettingsSurface / SettingsFormSurface 复用现有面板内容，避免复制业务逻辑。修改 main.dart、app_header.dart、settings_page.dart、metadata_server_settings.dart、tmdb_settings_dialog.dart、tmdb_id_guide.dart；新增 settings_navigation.dart 与 mobile_navigation_test.dart。

手机导航及相关桌面布局 13 项测试通过，涵盖 32px 状态栏安全区、三列委托、设置选中状态、重复点击不叠加、服务器/凭证路由及返回、桌面海报网格。当前整合状态完整回归为 142 通过、1 项显式联网测试默认跳过；静态分析无问题。Android 构建成功，未将模拟布局测试替代 Android 真机复测。

## 一级分类与二级设置

设置首页只显示“外观”“刮削服务”“关于”三行入口，具体主题控件、API 配置、日志开关等移入对应二级页面。桌面也使用独立设置页面；分类页面带返回入口，不在一级页并列展示具体控件。现有主题选择、服务器测试、凭证保存、ID 帮助和关于信息维持原功能。完整回归 142 项通过，静态分析无问题。

为用户安装提供 ARM64 Release APK，而非此前用于编译检查的 Debug 多架构包。Debug 包约 245 MB，旧通用 Release 约 109 MB；ARM64 Release 约 38 MB，主要通过移除调试运行时和其他 CPU 架构降低体积，未裁剪播放器功能。Release 沿用项目当前签名配置；旧 debug 构建记录仅作历史验证，不再作为本轮手机推荐下载。

## 交互视觉一致性检查

共用 NipaPlayStyle 统一文字、描边、填充、抬升与图标按钮的 8px 圆角、字号、间距及触摸尺寸。输入辅助/错误文字允许多行，避免提示被省略。新增 UniformActionBar，统一弹窗操作区为 48px 高度、等宽列、8px 间距与圆角；最多三个操作固定一行，超过三个时采用等列分组，避免默认 OverflowBar 将不同大小按钮堆成纵列。保留原回调、禁用/加载状态和主要操作的填充层级。

已接入媒体源编辑及确认、媒体源新增/移除、TMDB 凭证、作品元数据/角色排序/封面、扫描进度、目录操作、离线元数据设置等 14 处弹窗操作区，以及服务器设置页和封面裁剪页底部按钮。未修改扫描、认证或播放业务逻辑。

完整回归 149 项通过；9 项专项覆盖手机/Windows 媒体源真实编辑弹窗、240/320/600 宽度、深浅主题、同排等宽等高、8px 圆角、点击回调与加载禁用状态。静态分析无问题；原生手动视觉验收仍需设备复测。
