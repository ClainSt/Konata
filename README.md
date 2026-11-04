# CCPlayer

独立的 Windows / Android 动画媒体库播放器（**开发预览版，尚未达到首版验收标准**）。

技术基础：Flutter / Dart、Media Kit（libmpv）、SQLite。独立于 NipaPlay Personal，不包含其 Git 历史。

## 已具备的开发功能

- 单一海报墙：本地目录与 WebDAV 资源共用媒体库界面。
- 只读文件枚举：本地递归扫描；WebDAV PROPFIND Depth:1 递归。
- 基础动画目录、TMDB-ID 和文件名集数识别；正片 / 特典初步分类。
- TMDB / Bangumi 名称搜索与用户手动作品绑定，重扫时保留作品绑定。
- 本地数据库保存媒体条目、元数据及播放位置。
- 内置 Media Kit/libmpv 视频播放 UI；音轨 / 字幕选择入口。
- 检测同目录同名字幕并尝试自动加载（需要真机及真实 WebDAV 测试）。

## 尚未实现 / 不符合首版验收

- Windows 外部 MPV 启动、IPC、观看进度回写。
- WebDAV Digest 挑战、自动重试及坚固的认证代理；当前仅 Basic。
- WebDAV 源账号凭据现在保存在本地 SQLite 中，**请不要在此开发版输入真实云盘账号密码**。
- WebDAV 同步媒体库与观看进度；Bangumi 登录及观看记录同步。
- 大规模云盘扫描器的完整识别规则、增量删除与跨目录去重。
- TMDB 主动自动刮削、元数据与海报文件的离线缓存和稳定的 API 回退。
- Android 真实构建和播放、外部字幕/音轨效果、HDR/解码验收。
- 音频 CD 与 Scans 功能属于后续版本。

> 此仓库目前是可编译的开发骨架，不宜作为可安全连接个人云盘的生产版。

## 运行

```powershell
flutter pub get
flutter test
flutter analyze
flutter run -d windows
```

Android 需要 Flutter Android SDK、Java 及受支持的原生依赖。

## 设计边界

- 元数据源仅使用 TMDB 和 Bangumi，不以弹弹play作为元数据来源。
- 第一版 Android 仅需内置 MPV；Windows 需要内置与外部 MPV。
- 云盘扫描不得读取视频正文、修改或重命名云盘文件。
- TMDB-ID 目录绑定、人工修正关系与用户进度必须在正式版跨端同步。
- CDs、Scans 预留文件类型，但不在第一版实现。

## 验收目标

参照用户提供的八条《媒体库需求.txt》，前六条为第一版要求，第七、八条后续实现。
