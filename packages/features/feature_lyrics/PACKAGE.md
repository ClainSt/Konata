# `feature_lyrics`

Konata 歌词解析、多源竞速、双语与罗马音对齐、三级时间轴校准及卡拉 OK 逐字扫白业务包。

## 能力职责

- **领域层（`lib/src/domain/`）**：
  - 歌词候选项与评分模型（`lyric_candidate.dart`、`lyric_candidate_scorer.dart`）；
  - 检索请求生成与标题/歌手相似度（`lyric_search_query.dart`）；
  - 清洗与异常时间轴校验（`lyric_cleaner.dart`）；
  - 同源/跨源动态规划合并与倒排最长公共子序列交叉验证（`lyric_merger.dart`、`lyric_merger_cross_source.dart`）；
  - 逐字解析器与转换器（`ttml_lyric_converter.dart`、`yrc_lyric_parser.dart`、`qrc_lyric_parser.dart`）；
  - 三级偏移解析（单曲 > 专辑 > 有线/蓝牙路由，`lyric_offset_resolver.dart`）；
  - Bangumi 关联音乐曲目表别名补全（`bangumi_track_enricher.dart`）；
  - 帧同步时钟单调外推与 60 毫秒内柔性纠偏状态机（`karaoke_clock_extrapolator.dart`）。
- **数据层（`lib/src/data/`，0 Riverpod）**：
  - `KonataHttpClientPort` 传输适配（`lyric_http_transport.dart`）；
  - AMLL / 网易云 / QQ 音乐（含 `QrcDecryptor`）/ LRCLIB 多源适配器与竞速会话（`lyric_candidate_sources.dart`、`lyric_race_engine.dart`）；
  - 双库隔离持久化（`lyric_cache_store.dart`：在线检索与负缓存写入惰性 `cache.db`，用户手选与偏移落盘 `user_state.db`）；
  - 分命名空间设置存取（`lyrics_preferences.dart`，命名空间 `lyrics`）；
  - 多设备同步切片（`lyric_overrides_sync_slice.dart`，`sliceId: 'lyric_overrides_slice'`）；
  - 分级预取与解析协调器（`lyrics_resolver.dart`，非计量网络 2 首 / 计量网络 1 首）。
- **状态与界面（`lib/src/state/`、`lib/src/ui/`）**：
  - `LyricDisplayController`（0 Riverpod）：实现 `LyricDisplayPort`、双语译文/罗马音显示开关控制与句边界安全热替换；
  - `ImmersiveKaraokeSweepText`、`ImmersiveLyricLineLeaf`、`ImmersiveLyricsViewport`（100% 纯净纯白发光扫白视口与 `1.0 / 0.44 / 0.25 / 0.14` 景深分级，无漂浮胶囊遮挡）、`ImmersiveLyricControlSheet`（恒定深邃暗色玻璃，支持独立侧栏与 `embedded` 内嵌右上角菜单，提供双语开关、`-0.2s / 归零 / +0.2s` 快速偏移与词源切换）、`SettingsLyricsCard`（全量复用 `konata_design_system`，零空闲帧时钟空转）。
- **清单与离线基准**：
  - `featureLyricsManifest` 与 `createFeatureLyricsManifest`（声明播放侧栏 `lyrics_control`、设置分区、歌词源提供者与同步切片）；
  - `dart run packages/features/feature_lyrics/tool/lyric_bench.dart` 执行 70 首离线夹具评测。
