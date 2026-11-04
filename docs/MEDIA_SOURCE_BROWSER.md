# CCPlayer — 添加媒体与选择刮削文件夹

## 使用步骤

1. 点击右上角“添加媒体源”。
2. 选择 **WebDAV** 时填写 URL（例如 `http://server:29798/dav`）和凭证；选择 **本地** 时点击添加，将打开操作系统自带的文件夹选择器。
3. 添加成功自动进入浏览页面；已添加的媒体源可通过点击整张卡片或文件夹按钮再次进入浏览页面。
4. **目录浏览**：WebDAV 每进入一级目录才发送一次只读 `PROPFIND Depth:1`。展示文件夹及全部文件，不自动启动全盘扫描。支持根目录、返回上级、面包屑、重新加载、错误重试。
5. 选择刮削范围：导航进入目标文件夹后点击“此目录是单部作品”或“此目录是作品合集”，或者使用文件夹行右侧菜单。选择结果保存在 SQLite，重复进入页面仍在。
6. 底部可查看已选范围并删除。点击“扫描已选目录”后，扫描器仅访问选中的目录树。不会修改 WebDAV 文件内容。

## 示例

WebDAV 根路径为 `/dav`：

- 选择 `动画-单作品` 作为 **作品合集**：将 `动画-单作品/86 (2021) {tmdb-100565}` 等直属子目录各自建立作品。
- 选择 `动画-单作品/86 (2021) {tmdb-100565}` 作为 **单部作品**：将其中的 `[01].mkv` 等文件归入此作品。
- 选择本地目录 `D:\\Anime\\86 (2021) {tmdb-100565}` 作为 **单部作品**：即使视频直接位于选定文件夹根层，也应归入作品。
- 同一媒体源支持多个不重叠的刮削范围；相互包含的范围会被拒绝以避免重复扫描。

## 安全与限制

- 浏览和扫描只读取文件名、类型与文件大小，不会自动下载媒体内容、写入、删除或重命名云盘文件。
- WebDAV 目录浏览支持 Basic，并在服务器返回 401 Digest challenge 后交由 `HttpClient` 协商；目前仅模拟服务器测试过 Digest。
- 实际 `192.168.1.247:29798` 测试中，无凭证的只读 PROPFIND 返回 401，这是正常的鉴权要求；未访问或记录任何账号凭证。
- **目前仅实现选择范围和基础索引**：大规模同步、增量删除、跨目录识别、TMDB 主动刮削、播放代理 Digest、Android 实机选择器与 CloudDrive2 凭证下的目录浏览尚待验收。
- HTTP WebDAV 存在凭证与媒体传输安全风险；建议测试环境使用 HTTPS 或可信内网。

## 验证

- `flutter analyze --no-pub`：No issues found。
- `flutter test --no-pub`：11 项通过，包括目录归属、TMDB ID、中文 WebDAV href 与 401 Digest 目录挑战。
- `flutter build windows --release --no-pub`：成功。
- Windows EXE 已完成短时间启动存活冒烟检查；没有自动操作用户的云盘。

## Windows 安全存储适配

Windows 默认的 `flutter_secure_storage_windows` 原生插件依赖 ATL 头文件 `atlstr.h`，测试机器未安装该组件。
本项目改用从用户自有 NipaPlay Personal 工程提取的 Dart FFI Windows Credential Manager 实现，位于
`packages/flutter_secure_storage_windows`，用 `dependency_overrides` 固定本地实现，避免强制安装 Visual Studio ATL。
重新公开分发时，应单独核查该适配器及所依赖软件的许可证。
