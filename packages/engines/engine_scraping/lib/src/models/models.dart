/// 刮削领域模型与艺术图引用契约导出。
library;

export 'package:konata_contracts/konata_contracts.dart'
    show
        ArtworkRef,
        ArtworkSlot,
        ArtworkSource,
        AssetKind,
        EpisodeCategory,
        ExtraKind,
        LocalCustomArtworkRef,
        MediaSourceKind,
        RemoteArtworkRef,
        ScrapeStatus,
        SupplementaryAssetScope,
        TmdbCredentialKind,
        TmdbMediaType;

export 'artwork_ref_codec.dart';
export 'artwork_storage.dart';
export 'bangumi_music_track.dart';
export 'episode.dart';
export 'fanart_models.dart';
export 'managed_artwork.dart';
export 'media_source.dart';
export 'media_variant.dart';
export 'playback_record.dart';
export 'series_group.dart';
export 'tmdb_models.dart';
export 'work.dart';
