# 参与贡献 Konata

感谢你关注并愿意参与 Konata 的开发与维护。提交 Issue 或 Pull Request 前，请先阅读以下工程约定，以确保改动能够顺利合入。

## 核心原则

1. **媒体源严格只读**：对本地磁盘、WebDAV 与 SMB 媒体源保持只读，不向用户媒体目录写入缓存、刮削文件或自动生成字幕/歌词文件。
2. **Windows 纯绿色便携**：Windows 端所有数据库、凭据、日志与临时缓存均通过 `StorageRootService` 与 `path_provider_windows` 落在程序同级 `userdata/`、`cache/` 与 `photos/` 下，不写入 `%APPDATA%` 或系统 `%TEMP%`。
3. **严格单向四层架构**：遵循 `presentation -> application -> domain <- infrastructure`（外加 `composition` 平台组装根）：
   - `lib/domain/` 严禁导入 Flutter UI、`drift`、`http` 或 `dart:io`；
   - `lib/infrastructure/` 严禁反向引用 `application/` 或 `presentation/`；
   - 保持 Windows（`lib/main.dart`）与 Android（`lib/main_android.dart`）双入口平台裁剪干净，不把桌面独占依赖引入 Android 产物。
4. **统一视觉与交互**：所有弹窗、抽屉、下拉框、滚动条、提示与色值均复用 `lib/presentation/theme/` 与 `lib/presentation/widgets/design_system/`，禁止在业务页手写私有一套基础控件。
5. **编码与注释**：所有新增和修改的源码文件须为 **UTF-8 无 BOM**，注释统一使用简洁清晰的简体中文说明职责、规则与算法原理，不留死代码、过期 TODO 与历史变更日志。

## 本地开发与校验门禁

克隆仓库后运行：

```sh
flutter pub get
# 从 Konata-Native 拉取经 SHA-256 校验的 Windows / Android 原生运行时
dart run tool/fetch_native.dart
```

提交 PR 前，请确保本地完整通过统一门禁与注释检查：

```sh
# 静态分析（0 error / 0 warning / 0 info）
dart run tool/verify.dart analyze

# 自动化单测与刮削基准回归测试
dart run tool/verify.dart test

# 完整串行门禁（analyze -> test -> Windows Debug 构建）
dart run tool/verify.dart all
```

- 新增或修复领域规则、解析算法与核心状态流转时，必须补充对应的单元测试。
- 修改刮削、匹配或目录分析逻辑时，不得删减有效断言或放宽门禁校验。

## 提交与 Pull Request 规范

- 单个 PR 聚焦一个明确目标（功能、缺陷修复或单一模块重构），避免无关改动混杂。
- Commit 信息建议采用约定式前缀，例如 `feat(playback): ...`、`fix(scraping): ...`、`chore(docs): ...`。
- 涉及界面调整时，请在 PR 描述中附上桌面端或 Android 端的对比截图（注意遮挡个人路径、地址与凭据）。
- 切勿在提交中包含任何真实 API Key、签名密钥、密码或个人数据库文件。

## 许可证提示

向本仓库提交的原创代码贡献默认以 **GNU General Public License v3.0 or later（GPL-3.0-or-later）** 协议授权合入，详见 [`LICENSE`](LICENSE) 与 [`THIRD_PARTY_NOTICES`](THIRD_PARTY_NOTICES)。
