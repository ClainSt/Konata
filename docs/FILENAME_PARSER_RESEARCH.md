# 文件名解析器与发布组数据调研

调研日期：2026-11-05。范围：Anitomy 官方实现、Flutter 原生绑定、AniDB 官方资料；本次不接入库、不抓取组表、不改变解析代码。以下“接入成本”和实施建议是根据源码/官方能力作出的工程判断，未经过原生编译验证。

## 结论

当前继续使用 Dart 解析，并补充结构化、可追溯的文件名线索是合理的近期选择。它可以满足“展示文件名包含的技术信息和组名候选”，不能承诺完整理解任意发布命名。Anitomy 值得作为后续对照基线，但不能自动解决字幕组/压制组身份归因；现在为此引入 Windows 与 Android 原生构建链，收益不足以抵消接入和回归成本。

## Anitomy：已核对内容

| 项目 | 结果与依据 |
| --- | --- |
| 官方仓库 | [erengy/anitomy](https://github.com/erengy/anitomy)，C++ 动画文件名解析器 |
| 版本固定点 | `git ls-remote` 本次返回：master `a538eff670cb4666f8395cf66a9c29a535f2c383`；develop `8498b538f5ddeedaef1b3fa5ad4bf6d67dd67d35`；可见最高版本标签 `v1.4.0` 指向 `668cce41388c5d7d9800399ec59543796881a7d3`。分支与标签不可混作同一版本，采用时需固定 commit |
| 当前重写 | develop 是 v2.0 WIP，头文件实现，要求 C++23；官方 README 当前说明主要测试 MSVC，并说明 Clang 22 暂不可用。见 [README](https://github.com/erengy/anitomy/blob/8498b538f5ddeedaef1b3fa5ad4bf6d67dd67d35/README.md) |
| 旧实现 | master 使用 `Anitomy::Parse`、宽字符串及 `Elements`，与 develop 的 UTF-8 `parse` 返回值不同；不能混用包装代码。见 [master README](https://github.com/erengy/anitomy/blob/a538eff670cb4666f8395cf66a9c29a535f2c383/README.md) |
| 许可证 | MPL-2.0，见 [上游 LICENSE](https://github.com/erengy/anitomy/blob/8498b538f5ddeedaef1b3fa5ad4bf6d67dd67d35/LICENSE)。发布时应保留通知，并提供所分发 MPL 部分的源码获取方式；直接移植实现也需要处理其许可，不应当作自有正则代码。见 [Mozilla FAQ Q8–Q11](https://www.mozilla.org/en-US/MPL/2.0/FAQ/) |

官方说明解析依赖 token、关键词和模式推断，歧义命名可能无法修正；master README 直接给出了把组名误当标题及数字季名/集号无法区分的反例。因此“成熟解析器”不等于“可靠事实来源”。上述能力和边界来自两个分支的官方 README，而非第三方准确率宣传。

### 组名角色不能安全自动区分

核对固定 develop commit 的 [ElementKind 源码](https://github.com/erengy/anitomy/blob/8498b538f5ddeedaef1b3fa5ad4bf6d67dd67d35/include/anitomy/element.hpp)：存在 `ReleaseGroup`、`Language`、`Subtitles`、`VideoTerm`，没有 `EncodeGroup` 或 `SubtitleGroup`。`Subtitles` 字段存在不代表能识别字幕制作方。多个括号组、联合发布、转载/重封装名称都不能仅凭一个 release group 值分派到字幕组/压制组。

产品应保留“发布组候选/文件名标记”语义。只有明确的自描述语法或人工确认才设置更具体的角色；不能因为出现 CHS/CHT、x265、FLAC 就推断邻近名称为字幕或压制团队，也不能把候选作为可信身份标识。

## Windows / Android 接入成本

[Flutter 官方 FFI 文档](https://docs.flutter.dev/interop/bind-native-code)支持原生调用、生成绑定和构建钩子；C++ 仍需自行提供稳定 C ABI、UTF-8 输入/输出、内存释放和错误边界，不能直接把 C++ STL 返回值交给 Dart。

| 方案 | 判断 |
| --- | --- |
| develop + FFI | Windows 中等成本：MSVC 构建、C 包装、分发 DLL/代码资产和测试。Android 高成本：必须先实测 NDK/Clang 兼容性，官方 Clang 限制意味着不能宣称直接支持；还要处理目标 ABI 与 C++ runtime 分发 |
| 固定旧 master / v1.4.0 + FFI | 可单独验证旧实现的编译可行性，但仍有宽字符串转换、平台 ABI、构建和两平台回归成本；本次未编译，不声称 Android 已可用 |
| Dart 移植 | 无额外原生部署，但需要维护上游行为差异、测试语料与 MPL 通知；不是低成本“加一个包” |
| CLI 子进程 | Windows 可做离线比较工具；移动端生命周期、可执行文件打包与进程开销不适合作为当前默认解析路径（工程判断） |

## AniDB：验证状态与不抓取方案

尝试访问官方 [API](https://wiki.anidb.net/API)、[UDP API Definition](https://wiki.anidb.net/UDP_API_Definition)、[HTTP API Definition](https://wiki.anidb.net/HTTP_API_Definition)、[站点政策](https://anidb.net/policy)，本次均遭遇 HTTP 403。没有绕过访问限制，也没有用镜像或非官方代理替代来源。

因此本次**无法核实**：当前是否提供授权的全量发布组导出、精确 GROUP API 字段/登录及限速要求、数据再分发许可、是否存在稳定且足够的字幕/压制角色分类。不能把网上流传组表打包进应用，也不能把代码库许可证误当数据库使用许可。组名命中一个目录，本身仍不能证明该文件中该组承担什么角色。

无需 AniDB 数据即可完成当前功能：完全离线抽取原始括号/后缀标记、分辨率、来源、编解码、字幕语言、checksum 等线索；记录原始文本和来源位置；未识别内容保留为候选，不建立“全网组名数据库”。可允许用户本地确认角色或别名，并保存人工来源。若以后确实需要 AniDB ID，应另做经官方许可核实的按需查询，不抓网页、不默认上传文件名，也不在目前文档中承诺接口能力。

## 现有 Dart 解析的具体边界与后续验收

已检查仓库 `lib/core/personal_filename_parser.dart`：当前实现主要生成搜索关键词，会剥离所有开头方括号块及末尾标签块。它不是结构化 parser，注释中的“字幕组/压制组”也不是身份识别证据。结构化线索必须从原始 basename 提取，不能从已经清理过的搜索标题逆推；否则原始组名和技术标签已经丢失。

建议保留当前搜索行为并用独立结果表达候选、原文、位置和不确定性，避免把推断字段覆盖进可信媒体元数据。验收需覆盖中文/日文标题、数字标题、多个组标记、联合组名、剧场版/合集/特典、episode version、checksum、无组名及括号本来属于标题的情况。未知组和歧义字段应允许为空。后续若考虑 Anitomy，用固定版本与本项目真实命名语料离线比较，确认增益和两平台编译后再决定；本次没有声称任何准确率，也未构建应用。
