<div align="center">

<h1>Konata</h1>

<img src="assets/brand/icons/windows.png" alt="Konata · 泉此方" width="200">

<p>把收藏的动画，整理成自己的海报墙。</p>

<p>
  <img src="https://img.shields.io/badge/Flutter-02569B?style=for-the-badge&logo=flutter&logoColor=white" alt="Flutter">
  <img src="https://img.shields.io/badge/Dart-0175C2?style=for-the-badge&logo=dart&logoColor=white" alt="Dart">
  <img src="https://img.shields.io/badge/Windows-0078D4?style=for-the-badge" alt="Windows">
  <img src="https://img.shields.io/badge/Android-3DDC84?style=for-the-badge&logo=android&logoColor=white" alt="Android">
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

## 功能

### 媒体库

- 本地文件夹、WebDAV 与 SMB 媒体源统一管理。
- 按层级浏览目录，搜索当前目录的文件名或 TMDB ID，多选文件夹并扫描入库。
- 海报墙展示作品，详情页查看简介、评分、标签、剧集信息及角色 / 声优资料。
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

详细说明：

- [添加媒体与选择扫描目录](docs/MEDIA_SOURCE_BROWSER.md)
- [SMB 媒体源](docs/SMB_SOURCE.md)
- [TMDB / Bangumi 资料获取](docs/NIPAPLAY_SCRAPER_PORT.md)

## 从源码运行

准备 Flutter SDK 及对应平台的构建环境。Windows 需要 Visual Studio 的 C++ 桌面开发组件；Android 需要 Android SDK 和 Java 环境。

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
flutter build apk --release
```

## 反馈

欢迎通过 [Issues](https://github.com/ClainSt/Konata/issues) 提交问题和建议。报告问题时，请附上平台、复现步骤与必要的日志；涉及目录识别时，可提供去除私人信息后的目录结构和文件名示例。

## 致谢

- [Flutter](https://github.com/flutter/flutter)：跨平台界面框架。
- [Media Kit](https://github.com/media-kit/media-kit) / [mpv](https://github.com/mpv-player/mpv)：视频播放能力。
- [TMDB](https://www.themoviedb.org/) / [Bangumi](https://bgm.tv/)：作品与剧集资料。
- NipaPlay Personal：界面设计、媒体识别与 SMB 接入的参考和移植基础，相关说明见 [详情页移植记录](docs/NIPAPLAY_DETAIL_PORT.md) 与 [SMB 文档](docs/SMB_SOURCE.md)。
- [Kazumi](https://github.com/Predidit/Kazumi)：README 排版参考。

## 图标

应用图标采用《幸运星》泉此方的水粉风格头像。资源与导出说明见 [图标目录](assets/brand/icons/README.md)。
