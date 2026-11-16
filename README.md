<div align="center">

<h1>Konata</h1>

<img src="assets/brand/icons/android-round.png" alt="Konata · 泉此方" width="200">

<p>把收藏的动画，整理成自己的海报墙。</p>

<p>
  <img src="https://img.shields.io/badge/Flutter-02569B?style=for-the-badge&logo=flutter&logoColor=white" alt="Flutter">
  <img src="https://img.shields.io/badge/Dart-0175C2?style=for-the-badge&logo=dart&logoColor=white" alt="Dart">
</p>

<p>使用 Flutter 开发的个人二次元动画媒体库与播放器。只读接入本地文件夹、WebDAV 与 SMB，共用一座海报墙，浏览作品资料、特典与扫图画册，并在内置播放器或外部播放器间无缝接力续播。</p>

<p>
  <a href="#功能">功能</a> ·
  <a href="#开始使用">开始使用</a> ·
  <a href="#从源码运行">从源码运行</a> ·
  <a href="https://github.com/ClainSt/Konata/issues">问题反馈</a>
</p>

</div>

## 平台

- Windows x64（优先支持，纯绿色便携模式）
- Android ARM64（架构对齐，应用专属存储 + SAF 只读访问）

## 产品定位

Konata 聚焦简洁高颜值的二次元动画收藏与观影体验（简体中文）：

- **严格只读媒体源**：对本地磁盘、WebDAV（Basic / Digest）与 SMB 媒体源保持只读；删改作品仅作用于本地数据库与图片缓存，绝不删除用户物理文件。
- **双模音视频播放 + 外部热接力**：
  - 默认采用内置 `libmpv` 统一内核（视频与 CD 音轨驱动）；
  - 完整支持 **MPV（JSON IPC）/ PotPlayer（Win32 消息）/ 自定义外部音视频与看图程序** 作为全局备选及右键/播控栏单次快捷唤起通道，支持携带时间戳与音轨/字幕偏好热接力。
  - 远程 WebDAV / SMB 媒体经由本地 `127.0.0.1` `LocalStreamBridge`（支持 HTTP `206 Range`）零落盘流式透传。
- **内置 Scan 画册查看器**：本地与 WebDAV 分源限流生成 `360px` 轻量 WebP 微缩图至本地作品缓存，高清浏览时直接流式解码原图且零落盘。

## 功能

### 媒体库与合集

- 本地文件夹、WebDAV 与 SMB 媒体源统一管理，支持文件名与路径搜索、文件树勾选与增量扫描。
- 15 级集号提取、`MultiWorkSplitter` 合集拆分与 `WorkMatcher` 多信号加权匹配；歧义条目支持在「待复核」列表或抽屉中手动校准或混合拆并绑定。
- 自动区分 **正片 / 特典 / CD / Scan** 四大类别及二级子分类（OP/ED、PV/CM、OVA/OAD、特典映像等），支持「系列」成员下拉切换以及共享/季独占特典归属。
- 同作品、同季、同集的多个 BDRip 版本自动归组，支持音轨/字幕偏好与多版本点选切换。

### 作品资料

- TMDB + Bangumi 双源协同刮削（内置 DoH + TLS SNI、代理与备用镜像自动容灾回退），支持切换展示 TMDB / Bangumi 评分。
- 手动搜索绑定作品、编辑元数据、切换封面/背景原画（实时读取原图真实像素分辨率）。
- 作品图片统一归档至 `photos/<作品名> [<workId>]/` 下的 `posters/`、`backdrops/`、`logos/`、`thumbnails/`、`scans/` 五类按需目录。

### 播放与记录

- 支持内置播放与外部播放器（MPV / PotPlayer / 自定义程序）一键切换，自动读取并热同步 `mpv.conf` / `input.conf`。
- 同目录同名外挂字幕自动发现与挂载；基于观看区间合并的进度追踪（`WatchedTracker`）与全站播放记录断点续播。

### 外观与窗口

- Windows 11 原生 DWM 亚克力（Acrylic）/ 云母（Mica）透光材质与深色/亮色/跟随系统主题切换。
- 无框沉浸式作品详情页、悬浮毛玻璃弹窗与侧滑抽屉，全站统一设计语言与可拖拽滚动条。

## 开始使用

1. 打开「媒体源」，添加本地文件夹、WebDAV 或 SMB 地址（如 `smb://主机/共享名`）及凭据。
2. 浏览目录勾选需要扫描的动画文件夹，执行扫描入库。
3. 若遇到合集或歧义条目，可在「媒体库」待复核筛选或详情页菜单中手动搜索绑定或拆分源文件。
4. 进入详情页选择剧集、特典、CD 或 Scan 开始播放与浏览。

## 从源码运行

Windows 采用纯绿色便携存储：数据库（Drift SQLite）、加密凭据与 `photos/` 图片缓存均保存在程序同级 `userdata/`（调试模式位于项目根目录，已在 `.gitignore` 中忽略），临时文件位于 `cache/tmp/`，绝不写入 C 盘 `%APPDATA%` 或系统 `%TEMP%`。Android 使用应用专属存储。

### 前置环境

- Flutter SDK（Dart `^3.12.2`）
- Windows：Visual Studio C++ 桌面开发组件与 CMake
- Android：Android SDK 与 JDK 环境
- 本地固化原生库（`mpv 0.42.0` + `FFmpeg 9.0.2`）：构建前请按 [`tool/native/README.md`](tool/native/README.md) 准备库文件并放置于项目顶层 [`native/konata-native/`](native/konata-native/)（也可通过 `KONATA_NATIVE_ROOT` 环境变量指定）。Git 仅跟踪 `*-manifest.json` 校验清单，二进制文件已在 `.gitignore` 中忽略；缺失或 SHA-256 校验不符时构建会自动中止。

```sh
flutter pub get
flutter run -d windows
```

构建产物：

```sh
flutter build windows --debug
flutter build windows --release
flutter build apk --release --target-platform android-arm64 --split-per-abi
```

Android 正式签名需本机发布密钥及 `CCPLAYER_SIGNING_PASSWORD` 环境变量，可运行 `tool/build_signed_android.ps1`。

## 致谢

- [Flutter](https://github.com/flutter/flutter)：跨平台界面框架。
- [mpv](https://github.com/mpv-player/mpv) / [Media Kit](https://github.com/media-kit/media-kit)：底层视频播放内核与跨端适配基础。
- [TMDB](https://www.themoviedb.org/) / [Bangumi](https://bgm.tv/)：作品元数据与分集资料。
- 第三方源码与数据集授权说明见 [`THIRD_PARTY_NOTICES`](THIRD_PARTY_NOTICES)。
- [Kazumi](https://github.com/Predidit/Kazumi)：README 排版参考。

## 图标

应用图标导出母图位于 [`assets/brand/icons/`](assets/brand/icons/)，运行 `assets/brand/icons/export-icons.ps1` 可重新生成双端图标资源。
