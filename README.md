<div align="center">

<h1>Konata</h1>

<img src="apps/konata/assets/brand/icons/android-round.png" alt="Konata · 泉此方" width="200">

<p>把收藏的动画，整理成自己的海报墙。</p>

<p>
  <img src="https://img.shields.io/badge/Flutter-02569B?style=for-the-badge&logo=flutter&logoColor=white" alt="Flutter">
  <img src="https://img.shields.io/badge/Dart-0175C2?style=for-the-badge&logo=dart&logoColor=white" alt="Dart">
  <img src="https://img.shields.io/badge/License-GPL--3.0--or--later-blue?style=for-the-badge" alt="License: GPL-3.0-or-later">
</p>

<p>使用 Flutter 开发的个人二次元动画媒体库与一体化音视频播放器。只读接入本地文件夹、WebDAV 与 SMB，共用一座海报墙，浏览作品资料、特典、CD 专辑与扫图画册，并在内置 <code>libmpv</code> 播放器与桌面外部播放器间无缝接力续播。</p>

<p>
  <a href="#功能">功能</a> ·
  <a href="#开始使用">开始使用</a> ·
  <a href="#从源码运行">从源码运行</a> ·
  <a href="#许可证与版权说明">许可证</a> ·
  <a href="CONTRIBUTING.md">参与贡献</a> ·
  <a href="https://github.com/ClainSt/Konata/issues">问题反馈</a>
</p>

</div>

## 平台

- **Windows x64**（优先支持，纯绿色便携模式，基于独立桌面入口 `apps/konata/lib/main.dart`）
- **Android ARM64**（同源跨端设计语言与自适应外壳，应用专属存储 + SAF 只读访问，独立裁剪入口 `apps/konata/lib/main_android.dart`）

## 产品定位

Konata 聚焦简洁高颜值的二次元动画收藏、BDRip 资料库管理与高保真观影体验（简体中文）：

- **严格只读媒体源**：对本地磁盘、WebDAV（Basic / Digest）与 SMB 媒体源保持只读；删改作品仅作用于本地数据库与图片缓存，绝不删改用户物理文件。
- **单一 `libmpv` 内核双舞台 + 桌面外部热接力**：
  - 默认由内置 `libmpv` 统一驱动「原画视频舞台」、「流光音乐舞台」与三端可拖拽悬浮小窗，收起/展开不重建解码会话、不断音黑屏；
  - Windows 桌面端适配 **MPV（JSON IPC）/ PotPlayer（Win32 消息）/ foobar2000（`foo_beefweb` 分轨双向同步）** 作为全局备选或单次快捷唤起，支持携带时间戳热接力；Android 端自动裁剪全部桌面外部调用入口；
  - 远程 WebDAV / SMB 媒体经由本地 `127.0.0.1` `LocalStreamBridge`（支持强验证器 HTTP `206 Range` 续传与断连即时取消）零落盘流式透传。
- **全端内置 Scan 画册灯箱**：按源分级限流（本地并发 4、SMB 并发 2、WebDAV 严格单连接串行 + LIFO）仅落盘轻量 `360px` WebP 微缩图，高清浏览统一由内置 `ScanLightboxDialog` 流式解码且原图零落盘（Windows 保留对本地原图调用系统看图的轻量入口）。

## 功能

### 媒体库与合集

- 本地文件夹、WebDAV 与 SMB 媒体源统一管理，支持文件名/路径搜索、文件树勾选、忽略目录与增量扫描。
- 15 级集号提取（含多集合并区间如 `01-02`）、`MultiWorkSplitter` 合集拆分与 `WorkMatcher` 多信号加权匹配；歧义条目支持在「待复核」列表或抽屉中手动校准、拆并绑定或锁定归属。
- 自动区分 **正片 / 特典 / CD / Scan** 四大类别及二级子分类（无字幕 OP/ED、预告宣传、光盘菜单、音乐映像、OVA/OAD、特别篇与花絮等），支持「系列」成员切换以及共享/季独占附属资产归属。
- 同作品、同季、同集的多个 BDRip 版本自动归组，支持音轨/字幕偏好记忆与多版本点选切换。

### 作品资料与艺术图

- **TMDB + Bangumi + Fanart.tv** 多源协同刮削（内置离线 Bangumi↔TMDB/TVDB 二进制映射索引与静默热更新、DoH、代理、备用镜像自动冷却容灾以及无状态 Fanart 中继），支持切换展示 TMDB / Bangumi 评分与透明标题徽标（Logo）。
- 支持手动搜索绑定、逐字段人工锁定、编辑元数据以及切换封面/背景/徽标原画（实时读取原图真实像素分辨率）。
- 作品图片统一归档至 `photos/<作品名> [<workId>]/` 下的 `posters/`、`backdrops/`、`logos/`、`thumbnails/`、`scans/` 五类按需目录。

### 播放、字幕与音乐

- **高精画质与章节跳过**：支持 Windows D3D11 10-bit/HDR 渲染管线与 `vo=gpu-next`、Android 底层 Underlay `SurfaceView` 与画中画（PiP）、自动热同步 `mpv.conf` / `input.conf` 与 GLSL 着色器；内置两级防误判 **OP/ED 章节识别与跳过**（显式章节支持自动跳过，启发式候选仅提示手动跳过并区分 C-Part）。
- **无副作用字幕与字体包**：自动发现并挂载同目录同名外挂字幕；支持本地 `Fonts/` 原位只读直挂、本地/远程 `Fonts.zip` 与 `Fonts/` 单级哈希池解压、ASS `[Fonts]` 内嵌字体提取及可选逐 Origin 授权的 FontInAss 云端字体子集化；支持内存直注编码归一、OpenCC 繁简转换与时间轴调整。
- **无损音频与流光舞台**：支持整轨 + `.cue` 虚拟分轨、`gapless` 播放、WASAPI 共享/独占与 Android 14+ Bit-Perfect 音频安全链、内嵌/目录专辑封面提取与多源同步/逐字歌词展示。
- **观看进度追踪**：基于单调时钟并集时间线的有效完播率判定（`WatchedTracker`）与全站播放记录断点续播。

### 同步与备份

- **本地 `.konata` 备份与还原**：按需勾选设置、播放记录与媒体库目录等切片导出为带 SHA-256 校验的归档；恢复前先干跑预览新增/更新/删除计数，确认后在单一事务内原子写入。
- **WebDAV 多设备同步**：远端按「切片 × 设备」分片存放，未变化的分片零上传、零下载；WebDAV 密码仅存本机安全存储，凭据与本机绝对路径不参与同步。
- **Bangumi 追番进度同步**：使用个人访问令牌（PAT）直连官方 `api.bgm.tv`，单集完播后自动排队上报，网络异常时指数退避重试，令牌失效时提示重新绑定。

### 外观与跨端适配

- Windows 11 原生 DWM 亚克力（Acrylic）/ 云母（Mica）透光材质与深色/亮色/跟随系统主题切换。
- Android 平板与手机完全复用同源玻璃拟态设计系统与自适应悬浮胶囊导航，无框沉浸式作品详情页、可拖拽滚动条与可拖拽音视频悬浮小窗。

## 开始使用

1. 打开「媒体源」，添加本地文件夹、WebDAV 或 SMB 地址（如 `smb://主机/共享名`）及凭据。
2. 浏览目录勾选需要扫描的动画文件夹，执行扫描入库。
3. 若遇到合集或歧义条目，可在「媒体库」待复核筛选或详情页菜单中手动搜索绑定、锁定或拆分源文件。
4. 进入详情页选择剧集、特典、CD 或 Scan 开始播放与浏览。

## 从源码运行

Windows 采用纯绿色便携存储：全部业务数据落在程序同级目录（调试时为仓库根目录，均已在 `.gitignore` 中忽略），绝不写入 C 盘 `%APPDATA%`、`%LOCALAPPDATA%` 或系统 `%TEMP%`。

- `userdata/`：三库分治的 SQLite 数据库（`db/library.db` 媒体资产库、`db/user_state.db` 用户态库、按需惰性打开的 `db/cache.db` 缓存库）、DPAPI 加密凭据、配置与诊断日志；
- `photos/`：作品图片缓存（海报、背景、徽标、缩略图与扫图微缩图）；
- `cache/`：可随时清理的缓存，含 `tmp/` 临时文件与字幕暂存、`font_pool/` 字体池、`mpv_shader_cache/` 着色器缓存等。

Android 使用应用专属存储。

### 仓库结构

Konata v3 采用 Dart 原生 Pub Workspaces 多包结构，依赖严格单向，全仓不使用 `build_runner` 代码生成：

```text
apps/konata                 应用壳：Windows / Android 宿主装配与功能模块注册
packages/features/*         11 个功能模块（媒体库、详情、音视频播放、歌词、扫图、同步等）
packages/engines/*          4 个无界面纯 Dart 引擎（媒体源、刮削、播放、云盘）
packages/foundation/*       3 个底座包（契约、存储、设计系统）
packages/native_plugins/*   为绿色便携等需求修补的原生插件
```

开发规范见 [`AGENTS.md`](AGENTS.md)，各包职责与公开接口见各自目录下的 `PACKAGE.md`。

### 前置环境

- Flutter SDK（Dart `^3.12.2`）
- Windows：Visual Studio C++ 桌面开发组件与 CMake
- Android：Android SDK 与 JDK 17 环境
- 固化原生运行时（`mpv 0.42.0` + `FFmpeg 9.0.2`）：预编译二进制与完整交叉编译配方独立托管于 [ClainSt/Konata-Native](https://github.com/ClainSt/Konata-Native)，主仓仅保留经 SHA-256 锁定的 [`native/konata-native/*-manifest.json`](native/konata-native/)。首次克隆后运行 `dart run tool/fetch_native.dart` 即可自动拉取并完成全文件哈希校验（构建期也会二次校验，校验不符会自动中止）。

```sh
flutter pub get
dart run tool/fetch_native.dart
cd apps/konata
flutter run -d windows
```

如需 Fanart.tv 艺术图，可将根目录 `dart_defines.example.json` 复制为 `dart_defines.dev.json` 并填入密钥（已在 `.gitignore` 中忽略），运行时附加 `--dart-define-from-file=../../dart_defines.dev.json`；`verify.dart build` 会自动注入该文件。

构建与校验：

```sh
# 日常迭代：仅对改动及受影响的包执行 guard + analyze + test
dart run tool/verify.dart changed

# 阶段合入：串行执行 guard -> analyze -> test -> Windows Debug 构建
dart run tool/verify.dart all

# 手动发布构建（在 apps/konata 目录下执行）
cd apps/konata
flutter build windows --release
flutter build apk --release -t lib/main_android.dart --target-platform android-arm64 --split-per-abi
```

Windows 发布构建也可直接运行 `tool/build_windows_release.ps1`，调试符号会自动剥离到 `build/symbols/windows/`。

Android 正式签名需本机发布密钥及 `KONATA_SIGNING_PASSWORD` 环境变量，可运行 `tool/build_signed_android.ps1`。

## 许可证与版权说明

- 本项目原创源代码遵循 **GNU General Public License v3.0 or later（GPL-3.0-or-later）** 开源，协议全文见 [`LICENSE`](LICENSE)。
- **角色头像与品牌图标版权排除声明**：仓库内基于《幸运星》泉此方创作的二次创作头像与各平台应用图标（位于 `apps/konata/assets/brand/icons/`、`apps/konata/assets/icons/konata_icon.png`、`apps/konata/windows/runner/resources/app_icon.ico` 及 `apps/konata/android/app/src/main/res/mipmap-*`）**明确排除在 GPL-3.0-or-later 授权范围之外**，原角色著作权及相关权利归原权利方所有；任何衍生分发或分支项目均须自行移除或替换相关角色美术资产。
- 第三方源码、原生运行时（mpv / FFmpeg）、内置字体（Inter Variable / Noto Sans CJK SC）与开源数据集的完整授权及对应源码说明见 [`THIRD_PARTY_NOTICES`](THIRD_PARTY_NOTICES)。

## 致谢

- **界面与开发**：[Flutter](https://github.com/flutter/flutter) 与 Dart 跨平台生态。
- **音视频内核**：[mpv](https://github.com/mpv-player/mpv)、[FFmpeg](https://ffmpeg.org/)、[libplacebo](https://code.videolan.org/videolan/libplacebo) 与 [Media Kit](https://github.com/media-kit/media-kit)。
- **元数据与图集**：[Bangumi 番组计划](https://bgm.tv/)、[The Movie Database (TMDB)](https://www.themoviedb.org/)、[Fanart.tv](https://fanart.tv/) 与 [Wikidata](https://www.wikidata.org/)。
- **离线映射与名录**：[open-ani/bangumi-tmdb](https://github.com/open-ani/bangumi-tmdb)（CC BY 4.0）与 [filebot/data](https://github.com/filebot/data)（CC0 1.0）。
- **字幕与歌词生态**：[FontInAss](https://github.com/fontinass/fontinass)（云端字体子集化）、[LRCLIB](https://lrclib.net/) 与 [AMLL](https://github.com/Steve-xmh/amll-ttml-db) 歌词库。
