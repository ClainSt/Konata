<div align="center">

<h1>Konata</h1>

<img src="assets/brand/icons/android-round.png" alt="Konata · 泉此方" width="200">

<p>把收藏的动画，整理成自己的海报墙。</p>

<p>
  <img src="https://img.shields.io/badge/Flutter-02569B?style=for-the-badge&logo=flutter&logoColor=white" alt="Flutter">
  <img src="https://img.shields.io/badge/Dart-0175C2?style=for-the-badge&logo=dart&logoColor=white" alt="Dart">
</p>

<p>使用 Flutter 开发的个人动画媒体库与播放器。连接本地文件夹、WebDAV 或 SMB，共用一个海报墙，浏览作品资料、选择剧集，从上次看到的地方继续播放。</p>

<p>
  <a href="#功能">功能</a> ·
  <a href="#开始使用">开始使用</a> ·
  <a href="#从源码运行">从源码运行</a> ·
  <a href="https://github.com/ClainSt/Konata/issues">问题反馈</a>
</p>

</div>

> 当前为开发预览版。真实 NAS / WebDAV 环境和 Android 真机播放的兼容性仍在验证中，建议先用测试媒体源体验。

## 平台

- Windows
- Android

## 产品目标

Konata 以轻量级应用为基础，核心聚焦媒体库、海报墙与基础刮削、忠实还原源视频画面的内置播放器，以及基础播放记录、断点续播和备份与恢复。播放质量与稳定性优先于极限瘦身。

增强能力采用内置可选功能，不再开发应用插件市场或下载脚本执行机制。设置 → 扩展位于“关于”上方：动画可选“关闭 / 角色 / 声优”，真人影视使用开关。详细设置只在启用后出现在“刮削服务”。

角色/声优和真人演职员由内置 Dart 服务按需加载；关闭时取消相关网络请求、停止任务、释放页面图片与临时缓存。保留已有资料、设置和备份能力。首次升级迁移已知官方插件的启用状态与图片选择，旧插件文件保留用于回退，不再执行。

资源目标是关闭后无持续业务活动、独占资源可回收，不代表代码从安装包消失或系统进程内存立即归零。双端验证范围与成本见 [内置可选功能](docs/OPTIONAL_FEATURES.md)。

## 功能

### 媒体库

- 本地文件夹、WebDAV 与 SMB 媒体源统一管理。
- 按层级浏览目录，搜索当前目录的文件名或 TMDB ID，多选文件夹并扫描入库。
- 海报墙展示作品，详情页查看简介、评分、标签、剧集信息；角色 / 声优及真人演职员资料按需启用。
- 识别季度与集数，区分正片、特典、PV、CM、OVA、OAD、NCOP、NCED 等内容。
- 同作品、同季、同集的多个视频版本合并展示，保留各自的源文件记录。
- 编辑媒体源名称、地址与登录凭证。
- 隐藏作品、管理与恢复已隐藏作品，不删除媒体源中的文件。

### 作品资料

- 扫描后自动通过 TMDB / Bangumi 获取作品资料。
- 按名称搜索并手动绑定作品，编辑元数据与封面。
- 支持配置、切换并测试 TMDB API Key / Read Access Token。
- 作品资料与观看进度保存在本地，已缓存的资料可在元数据服务暂不可用时继续查看。

### 播放

- 基于 Media Kit / libmpv 的内置视频播放器。
- 播放 / 暂停、进度跳转、音轨与字幕选择。
- Android 起播时自动进入横向全屏。点一下画面可显示返回键、片名和进度条；右滑快进，左滑回退，在右半屏向上或向下滑动可调节音量。
- Windows 和 Android 均支持在播放器设置中选择自己的配置文件夹，每次起播重新读取 `mpv.conf` 和 `input.conf`。
- 检测同目录同名外部字幕并尝试自动加载。
- 自动保存播放位置，支持断点续播。

### 外观

- 日间模式、夜间模式与跟随系统。
- 可选择主题色，并保存外观设置。
- 泉此方主题应用图标：Windows 透明背景，Android 白底自适应图标。

## 开始使用

1. 打开右上角添加媒体菜单，选择本地媒体或网络媒体。
2. 本地媒体选择文件夹；网络媒体填写 WebDAV 或 SMB 地址及登录凭证。SMB 地址格式为 `smb://主机/共享名`。
3. 浏览目录并勾选需要加入媒体库的文件夹，点击「扫描已选目录」。
4. 在扫描进度中查看索引与资料获取情况。需要手动修正时，进入作品详情页，通过右上角菜单编辑元数据或封面。
5. 选择剧集开始播放；已有观看进度的内容可以继续播放。

## 从源码运行

Windows 采用便携存储：媒体库、设置、图片缓存和加密凭据放在 `Konata.exe` 同级的 `userdata/`，临时文件放在 `cache/tmp/`。首次启动会复制旧版 AppData 数据，原件保留供回退；程序目录不可写时会提示，不会悄悄切回 C 盘。升级前关闭程序，将整个 `userdata/` 随程序保留；不要直接删除含数据的旧便携目录。Windows 凭据受当前账户保护，换电脑或账户后需要重新填写。Android 仍使用应用专属存储。

准备 Flutter SDK 及对应平台的构建环境。Windows 需要 Visual Studio 的 C++ 桌面开发组件；Android 需要 Android SDK 和 Java 环境。

当前源码使用固定版本的本地原生库（mpv 0.42.0、FFmpeg 9.0.2）。构建前须按 `tool/native/` 中的脚本准备 Windows x64 或 Android ARM64 库及其校验清单，放入 `.dart_tool/konata-native/`，也可通过 `KONATA_NATIVE_ROOT` 指定目录。原生二进制不存入源码仓库；缺失或校验不符时构建会停止。

```sh
flutter pub get
flutter run -d windows
```

Android 连接设备后，使用 `flutter devices` 查看设备 ID，再运行：

```sh
flutter run -d <设备ID>
```

构建安装包：

```sh
flutter build windows --release
flutter build apk --release --target-platform android-arm64 --split-per-abi
```

Android 正式签名需要本机发布密钥及 `CCPLAYER_SIGNING_PASSWORD` 环境变量。项目维护者可运行 `tool/build_signed_android.ps1`，在本机交互输入密码；密钥和密码不上传仓库。

## 反馈

欢迎通过 [Issues](https://github.com/ClainSt/Konata/issues) 提交问题和建议。报告问题时，请附上平台、复现步骤与必要的日志；涉及目录识别时，可提供去除私人信息后的目录结构和文件名示例。

## 致谢

- [Flutter](https://github.com/flutter/flutter)：跨平台界面框架。
- [Media Kit](https://github.com/media-kit/media-kit) / [mpv](https://github.com/mpv-player/mpv)：视频播放能力。
- [TMDB](https://www.themoviedb.org/) / [Bangumi](https://bgm.tv/)：作品与剧集资料。
- 媒体识别、界面参考及 SMB 接入的来源和授权见 [第三方说明](THIRD_PARTY_NOTICES)。
- [Kazumi](https://github.com/Predidit/Kazumi)：README 排版参考。

## 图标

应用图标采用《幸运星》泉此方的简化贴纸风头像，搭配代表另外三位主角的粉色与紫色星星。Windows 使用透明背景图标，Android 使用白底自适应图标；README 展示同一构图的圆形版本。导出母图位于 [图标目录](assets/brand/icons)，运行 `assets/brand/icons/export-icons.ps1` 可重新生成两端图标资源及圆形展示图。
