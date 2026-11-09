# 旧 Windows 增强引擎退役核验

2026-11-08。属于核心播放器的启动路径收敛，不是把基础解码改为插件。

## 决定与范围

删除设置中的增强引擎卡片、下载、归档导入、切换、哈希检查、启动选择及其专属工具和测试。主程序直接初始化随包内核。保留mpv.conf / input.conf 编辑与导入、外部配置目录、现有原生渲染实现和通用原生内核测试。随后按用户最新要求移除解码模式选择，默认自动且正常回退静默；手写配置中的明确指定继续生效。

旧入口最初用于弥补旧默认内核缺少 TrueHD 的问题。当前 Windows 构建必须使用本地清单校验的 mpv 0.42.0 / FFmpeg 9.0.2，已不再使用当时的旧默认内核。不能用“插件系统已有”作为删除原生引擎的理由：详情插件 API 并不支持替换 libmpv。

## 实际证据

- 当前 DLL SHA-256：`151b6a1474497dd057afd3d7bf3574547139a9a2ca6f890b4d8cea9558be4a10`，68,158,976 字节，与构建清单一致。
- 当前内核运行时报告 mpv v0.42.0 / FFmpeg 9.0.2，496 个解码器条目；全部 14 项必要 codec 检查通过，包括 H.264、HEVC、AV1、TrueHD、MLP、FLAC、AAC、DTS。构建配置包含 LuaJIT、JavaScript、libass、Vulkan 和色彩管理。配置声明不是脚本、画质或硬件兼容性的完整验收。
- 实际 TrueHD 样片解码为六声道，切换 AAC 成功，无播放器错误；测试输出使用 ao=null，不代表扬声器、声道映射或声音质量验收。
- 实际 mpv.conf 读取及 input.conf 键绑定测试通过。
- 原始报告：`build/engine-audit-current.json`、`build/engine-audit-legacy.json`、`build/engine-audit-current.log`、`build/engine-audit-audio.log`。

## 不能声称两套内核完全等价

旧增强包为 mpv v0.42.0-1-g3138fc8ee / FFmpeg N-128420-gbaa68e68b，524 个解码器条目。按 codec 名称去重后，旧包独有：adpcm_circus、adpcm_citrix、adpcm_ima_escape、adpcm_ima_hvqm2、adpcm_ima_hvqm4、adpcm_ima_magix、adpcm_ima_pda、adpcm_n64、adpcm_psxc、adpcm_rhetorex、ahx、avs2、avs3、imm6、pcm_dvda、rw2。旧包还含 VapourSynth、Rubber Band、DVD 导航等额外构建能力。

这些不属于当前声明的基础 BDRip 能力，不为它们继续保留整套应用内引擎管理。需要这些能力的旧配置不能保证在当前内核工作；后续如有实际需求，应独立评估平台专用扩展及维护成本，不能假称当前详情插件即可实现。当前清理不代表已完成全部播放画质、HDR 或长期稳定性验收。

## 数据与回退

不删除应用数据目录中的 `mpv-engine`、历史 DLL、`mpv_enhanced_engine_enabled` 设置或用户 MPV 配置。新版忽略旧引擎选择；返回此前支持增强引擎的应用版本仍可读取原设置和文件。本次不自动回收旧 DLL 的磁盘空间。正式发布记录与旧发布包保持保留，验证包单独交付。

## 成本与验收范围

不增加依赖、资源、缓存或后台任务。减少一条 Windows 内核下载和启动分支，Android 不再初始化无用的引擎选择服务。原生内核文件保持相同；无法据源码删除行数推断安装包缩小幅度。CPU、GPU、内存、电量没有独立前后测量，不报告量化收益。双端编译与插件卸载界面、MPV 配置回归分别检查；构建体积及本次验证结果记录在 `release/validation/plugin-uninstall-20261108/verification.json`。

本次双端 Release 验证包编译成功；相同配置对比前一目录验证包，Windows 便携目录减少 65,024 字节（127,868,044 → 127,803,020），Android ARM64 APK 仍为 60,268,496 字节。包含卸载确认与清理的共同影响，不能单独归因或推广到其他构建配置。静态分析通过，相关测试 26 项通过、无跳过；平板外部目录安装/取消卸载/确认卸载通过，完整 Android 验证包已安装并启动到设置页。验证包不是正式签名更新，未更新 latest-build.json。
