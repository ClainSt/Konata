/// Konata v3 歌词能力业务包唯一公开出口。
///
/// 统一导出领域解析模型、双源与多源竞速器、双库存储与同步切片、状态协调控制器、
/// 沉浸扫白与控制界面组件、Riverpod 依赖注入以及扩展声明清单。
library;

export 'src/data/amll_lyric_provider.dart';
export 'src/data/lrclib_lyric_provider.dart';
export 'src/data/lyric_cache_store.dart';
export 'src/data/lyric_candidate_sources.dart';
export 'src/data/lyric_http_transport.dart';
export 'src/data/lyric_overrides_sync_slice.dart';
export 'src/data/lyric_race_engine.dart';
export 'src/data/lyrics_preferences.dart';
export 'src/data/lyrics_resolver.dart';
export 'src/data/netease_lyric_provider.dart';
export 'src/data/qqmusic_lyric_provider.dart';
export 'src/data/qrc_decryptor.dart';
export 'src/domain/bangumi_track_enricher.dart';
export 'src/domain/karaoke_clock_extrapolator.dart';
export 'src/domain/lyric_candidate.dart';
export 'src/domain/lyric_candidate_scorer.dart';
export 'src/domain/lyric_cleaner.dart';
export 'src/domain/lyric_merger.dart';
export 'src/domain/lyric_offset_resolver.dart';
export 'src/domain/lyric_search_query.dart';
export 'src/domain/qrc_lyric_parser.dart';
export 'src/domain/ttml_lyric_converter.dart';
export 'src/domain/yrc_lyric_parser.dart';
export 'src/manifest.dart';
export 'src/providers.dart';
export 'src/state/lyric_display_controller.dart';
export 'src/ui/immersive_karaoke_sweep_text.dart';
export 'src/ui/immersive_lyric_control_sheet.dart';
export 'src/ui/immersive_lyric_line_leaf.dart';
export 'src/ui/immersive_lyrics_viewport.dart';
export 'src/ui/settings_lyrics_card.dart';
