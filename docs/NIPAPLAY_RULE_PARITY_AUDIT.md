# NipaPlay Personal 与 CCPlayer 刮削规则对照（2026-11-05）

本次逐项阅读本机 NipaPlay-Personal 的实际源码，而非仅按文档推测。目标是复现用户收藏的匹配结果；不引入弹弹play元数据接口，不整体复制数据库或 Rust 播放运行时。

## 对照范围

| 阶段 | Personal 源文件/入口 | CCPlayer 对应文件 | 结果 |
|---|---|---|---|
| 只读目录枚举、作品归属 | services/cloud_media_scanner.dart：scan、workDirectory、parseTmdbId | selected_scanner.dart、auto_classifier.dart、catalog.dart | 按原始目录保持作品身份，同 TMDB ID 的不同季目录不合并；保留嵌套 ID 优先与辅助目录规则 |
| TMDB 标记语法 | cloud_media_scanner.dart：parseTmdbId、parseTmdbType | catalog.dart：tmdbId、tmdbType | 补齐 tmdbtv/tmdbmovie/tmdbid、方括号、等号与带 type 的写法；明确电影标记优先 |
| 文件名搜索词 | utils/media_filename_parser.dart；rust/src/api/media_metadata.rs：media_extract_anime_title_keyword | personal_filename_parser.dart | Dart 回退算法对应；Rust 的路径分隔、标签清理和集数移除规则已阅读核对 |
| 年份与搜索变体 | services/cloud_media_scraper.dart：_releaseYear、_addTitleQueryVariants、_scrapeBangumiByTitle | work_season.dart、personal_scraper.dart | 原目录年份优先；补齐英文序数季度变体；年份从 ±1 放宽改为精确年份核验 |
| TMDB ID 直接查询 | tmdb_metadata_service.dart：scrapeWork | personal_scraper.dart：_tmdbById | ID 优先，类型可回退；不将 movie 自动解释为剧场版 |
| 同 ID 多季消歧 | cloud_media_scraper.dart：_applyBangumiPosterForTmdbId、_scrapeBangumiByTitle；tmdb_metadata_service.dart：loadEpisodeSeasons | work_season.dart、personal_scraper.dart、detail_metadata.dart | Personal 通过标题提示和补充元数据区分季；CCPlayer 从原目录恢复季号和年份，读取 TMDB 季度资料，避免用系列通用海报覆盖三季 |
| Bangumi 回退 | cloud_media_scraper.dart：_titlesMatch、_scrapeBangumiByTitle | personal_scraper.dart：_bangumi | 保留公开搜索、中文名优先、年份与 TMDB-ID 冲突核验；有年份时允许副标题包含匹配，仍要求唯一条目 |
| 正片/特典分类 | utils/cloud_media_file_classifier.dart | cloud_media_file_classifier.dart | 逐文件 diff 后确认语义一致，差异为 Dart 格式；移植 Personal 的纯规则测试验证 |
| 集数入库 | cloud_media_scanner.dart：episodeNumberFromNameInDirectory | catalog.dart：indexVideo | 修正接线：入库不再用简化正则，而用同一套目录感知解析；避免 86、22/7 等数字番名被当集数 |
| 季度入库 | utils/cloud_media_asset_presentation.dart：explicitSeasonNumber | catalog.dart：detectedSeason | 修正中文 第二季/第三季；S02E01、Season 2、2nd Season 等复用公共规则 |
| 绝对集数/多季合集 | cloud_media_asset_presentation.dart：episodeCoordinates | 同名算法与详情适配层 | 连续集数按季度集数扣减；显式季号优先；S1+S2/S01-S02 等合集不能被年份误钉为第一季 |
| 季/集剧照与标题 | tmdb_metadata_service.dart：loadEpisodeSeasons | detail_metadata.dart、nipaplay_detail_page.dart：episodeInfo | 补齐原目录季度上下文；旧索引 season=1 时中文目录仍可定位第二/三季；禁止向其他季回退第一季标题 |
| Bangumi 剧集补充 | tmdb_metadata_service.dart 补充资料路径 | detail_metadata.dart | 按当前目录季度保存 Bangumi 剧集标题，避免第二季标题落进第一季缓存 |
| OVA/OAD/SP | cloud_media_asset_presentation.dart：mapSpecialEpisodes | 同名算法 | 原测试覆盖同年特典池、OVA/OAD 归族、显式编号、稳定顺序和不确定时不猜测 |
| CM/PV/MENU/NCOP/NCED/预告 | classifier + presentation | 同名算法、详情 UI | 不误配为正片或 OVA；展示标签/占位封套；未知特典保留清理后的文件名 |
| 人工编辑与数据保护 | cloud_media_index_database.dart 关系锁定/封面覆盖 | catalog.dart：applyScrapedWork、asset_overrides、manual_cover_url | 自动刮削跳过人工作品锁；不修改原文件、作品路径身份、assetId 和进度 |
| 缓存与重新刮削 | tmdb_episode_seasons 缓存 | detail_metadata schema 7、coordinator | 新版详情重读季度资料；重新扫描时旧的无季名自动匹配条目也进入修复队列，而不因已有封面而跳过 |

## 用户样本的完整回归

同一 TMDB ID 65844 的以下三目录：

- 为美好的世界献上祝福！ (2016) {tmdb-65844}
- 为美好的世界献上祝福！ 第二季 (2017) {tmdb-65844}
- 为美好的世界献上祝福！ 第三季 (2024) {tmdb-65844}

测试模拟旧版已经把三者改为相同名称和第三季海报的状态，实际调用目录索引、元数据解析与 SQLite 更新，核对三作品分别得到第1/2/3季名称与季度封面，季号为1/2/3，且保留独立文件和进度。年份与显式季号冲突时拒绝自动确认。

## 测试入口

- test/season_identity_test.dart：用户三季目录的索引到落库回归、ID 语法、严格年份、合集保护。
- test/personal_classifier_parity_test.dart：从 Personal scanner 测试提取的纯规则样本，覆盖压制组编号、中文/日文集数、数字番名、预告/特典、独立电影。
- test/personal_presentation_parity_test.dart：Personal 的季集定位、连续编号、特典分类与 OVA/OAD 映射样本。
- 原有 personal_scraper、detail_metadata、selected_scanner、selected_scan_workflow、work_edit、work_visibility 测试验证实际调用与数据保护。
- 引用的 Personal 测试采用其 MIT 许可证，见 NIPAPLAY_REFERENCE_LICENSE。

## 明确保留的差异与验收边界

1. Personal 使用弹弹play TMDB 反查和补充季度资料；CCPlayer 不调用这些服务，使用 TMDB 季度接口及 Bangumi 公开资料。没有这些来源时不能保证与其匹配率完全相同。
2. Personal 在宽松包含匹配中可采用首个通过项；CCPlayer 保留唯一性检查，缺少年份时只接受精确标题。不用不确定的结果伪造成功。
3. CCPlayer 优先季度 TMDB 海报，Bangumi 作为备用；Personal 的补充匹配可能选中 Bangumi 封面，具体图片不承诺逐像素相同。手动封面保持优先。
4. 本次验证是可复现规则/SQLite 测试和双平台构建，不代表所有真实媒体库与网络返回都已验收；无条件宣称全量数据100%一致是不准确的。
5. 当前已错误匹配的自动作品，请在媒体源目录里重新勾选并扫描；不需要删除媒体源或源视频。人工锁定的作品不会被自动改写。
