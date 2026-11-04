# CCPlayer 刮削方案：NipaPlay Personal → TMDB / Bangumi

## 源码对照

参考 NipaPlay Personal 的 `lib/services/cloud_media_scraper.dart`、`tmdb_metadata_service.dart`、`bangumi_api_service.dart`、`lib/utils/media_filename_parser.dart`、`cloud_media_file_classifier.dart`、`cloud_media_asset_presentation.dart` 与 `anime_detail_metadata.dart`。

NipaPlay Personal 中弹弹play的 TMDB ID 反查、Bangumi 详情解析、搜索与封面升级路径没有引入。CCPlayer 不调用任何弹弹play API，也不需要它的授权或服务。

## 实际执行顺序

1. **媒体扫描**：只枚举用户勾选的本地或 WebDAV 目录，文件归属自动推断；视频文件不执行 GET、哈希、重命名或写入。
2. **元数据刮削**：扫描完成后立即自动刮削本次扫描涉及的、缺少海报或待复核的作品，无须底部弹窗确认；也可从媒体源卡片点击 ✨ 手动重试，此步骤不会重新扫描云盘。
3. **TMDB ID 优先**：直接查询 `/tv/{id}`，若不存在则查 `/movie/{id}`。支持已配置的 Read Access Token 或 API Key（两者保留在系统安全存储）。
4. **无 TMDB ID**：使用作品名与 NipaPlay Personal Dart 版文件名清理器提取的候选词查询 TMDB TV/电影，仅对**唯一且标题、年份相符**的结果自动绑定。
5. **Bangumi 公共回退**：通过公开 `/v0/search/subjects` 和 `/v0/subjects/{id}` 查找；核对作品名称、年份及可用时的 TMDB ID，避免误绑。无需 Bangumi 登录。
6. **图片优先级**：TMDB 海报优先，另外存储 Bangumi 封面备用链接。图片显示时若 TMDB 主图加载失败，尝试备用图；此机制不是完整离线封面缓存。
7. **用户人工锁定优先**：`manual_lock=1` 的作品自动刮削跳过；`asset_overrides` 保护视频分类、集数和季度，观看历史保持原有 assetId。
8. **待复核**：无法唯一确认的匹配结果不落库为准确匹配。可从详情页「···」→「编辑元数据」手动搜索并绑定 TMDB/Bangumi；已移除独立「关联管理」界面，历史人工关系数据继续保留。
9. **旧索引升级**：SQLite v10 中保留早期的离线索引修复迁移（v8 阶段）及新增手动封面来源字段；基于本地文件名为旧索引补充集数和特典类型（不接触云盘文件），人工锁定文件不调整。
10. **详情页**：按 TMDB season/episode 读取剧集图，特典只对可匹配的 OVA/OAD/SP 关联官方特典条目；CM/MENU 等没有官方剧照时展示中性占位而非整部动画共用同一背景。使用 NipaPlay Personal 的角色排序与上部裁切、标签优先级。多压制版本归并为一张剧集卡片，点开可选具体文件。

## 重要限制

- **不是完整的原项目逐文件复制**：它依赖多套状态管理、数据库、缓存、Rust 及弹弹play路径。现阶段只引入不依赖弹弹play的核心算法，再通过 CCPlayer 自己的 Flutter/SQLite 服务适配。
- 当前是**用户触发的批量元数据刮削**，不是无人值守全库计划任务。对规模较大的目录，这可以避免一次扫描触发上千个搜索请求。
- 没有下载/保存全部高清图片到离线文件，也没有实现 WebDAV 视频即时抽帧；无法从 TMDB 确定的真实剧照会显示占位图。
- 真实 CloudDrive2、国内 IP、Android 真机及大规模扫描性能仍需要实测。单元测试仅证明确定的规则和数据更新行为。

## 验收重点

- 有 TMDB ID 的 TV 与电影、无 TMDB 证书时的 Bangumi 回退。
- 名称歧义和年份不符时不误绑定；已人工绑定的海报不被覆盖。
- `[压制组] 动画名 [01]` 的老索引可以本地补回集数，不重新扫描 WebDAV。
- 同季同集不同压制版本合并为一张卡片；原始文件和观看历史仍各自保留。
- SP/CM/PV/OVA/OAD/NCOP/NCED/MENU 分类，以及 Bangumi 的角色排序/裁切、TMDB 剧集图片与标签展示。
