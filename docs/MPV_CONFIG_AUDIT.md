# MPV 配置接入可行性审查（尚未修改播放器）

检查对象：CCPlayer 当前 `media_kit 1.2.6`、`media_kit_video 2.0.1`、`lib/ui/watch_page.dart`。

## 源码确认

- `WatchPage.initState` 当前直接 `Player()`，随后创建 `VideoController`；应用未提供独立 MPV 配置目录。
- 当前 `PlayerConfiguration` 公开 vo、osc、libass、bufferSize、日志级别、协议白名单等参数，但**没有** `config`、`config-dir`、`input-conf` 和 `load-scripts` 入口。
- media_kit 的 NativePlayer 在内部生成 libmpv 初始化 options 后立即创建上下文，外部只在该初始化之后取得可调用播放器对象。
- libmpv API 文档明确列出 `config`、`config-dir`、`input-conf`、`load-scripts`、`script` 为初始化前必须设置的选项。因此播放开始后调用 `setProperty` 不能等价实现完整配置与脚本加载。

## 实施建议（需要用户选择后再改底层依赖）

A. **建议：维护最小本地 media_kit 1.2.6 补丁**，仅增加可选配置目录、配置加载、input.conf 与 scripts 初始化参数，并带双端测试；其余 Player API 不变。参考现有对 media_kit_video 本地补丁的做法，记录补丁范围与上游版本。优点是可保留现有播放层，缺点是后续更新 media_kit 时需维护补丁。

B. 更换播放器底层/自行封装 libmpv：代码和回归范围更大，不建议直接替换现有媒体库播放架构。

C. 仅把 mpv.conf 解析为播放器运行期 properties：不能完整支持 input.conf、Lua 及初始化选项，**不能**称为达到独立 MPV 相同效果，不建议。

## 默认配置边界

mpv_PlayKit 由 hooke007 维护，Windows portable_config 中存在 mpv.conf、input.conf 及脚本相关文件，但还可能依赖随包二进制、shader、补帧组件和平台专用路径。即使成功加载配置，也不能据此保证画质和独立 MPV 完全一致。须审查许可、配置默认值、OS 条件、Android 不支持的选项，以及用户导入/恢复配置和脚本权限边界。

暂不复制 PlayKit 配置，不开放脚本执行，不更改当前正常播放器路径。

资料：
- https://github.com/mpv-player/mpv/blob/master/include/mpv/client.h
- https://pub.dev/documentation/media_kit/latest/media_kit/PlayerConfiguration-class.html
- https://github.com/hooke007/mpv_PlayKit/wiki/2_portable_config
