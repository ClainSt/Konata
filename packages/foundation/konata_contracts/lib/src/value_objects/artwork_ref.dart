/// 作品艺术图远程来源类型。
enum ArtworkSource {
  /// TMDB 官方图床。
  tmdb,

  /// Bangumi 官方条目封面源。
  bangumi,

  /// Fanart.tv 高清透明 Logo / 背景源。
  fanart,
}

/// 作品艺术图槽位类型。
enum ArtworkSlot {
  /// 竖版海报封面。
  poster,

  /// 横版无字背景图。
  backdrop,

  /// 透明 PNG 标题徽标。
  logo,
}

/// 作品艺术图强类型引用（统一封面、无字背景与透明 Logo 的同步与锁定语义）。
///
/// - [RemoteArtworkRef]：仅同步轻量来源引用与人工锁定态，同步端按引用自行拉取并缓存至本机 `photos/`；
/// - [LocalCustomArtworkRef]：本机用户自定义图片绝不向同步载荷泄漏本机绝对路径，
///   对端收到后自动回退获取该作品对应默认源的默认图片。
sealed class ArtworkRef {
  /// 构造艺术图引用基类。
  const ArtworkRef({required this.locked});

  /// 创建远程艺术图来源引用。
  const factory ArtworkRef.remote({
    required ArtworkSource source,
    required String uri,
    bool locked,
  }) = RemoteArtworkRef;

  /// 创建本机自定义图片引用。
  const factory ArtworkRef.localCustom({
    required String localPath,
    bool locked,
  }) = LocalCustomArtworkRef;

  /// 是否已被用户人工锁定（锁定后自动刮削不得覆盖）。
  final bool locked;

  /// 序列化为本地数据库持久化 JSON（完整保留本机自定义路径）。
  Map<String, Object?> toLocalJson();

  /// 序列化为跨设备备份 / WebDAV 同步载荷。
  ///
  /// 本机自定义图片返回 `null`，确保绝不泄漏本机绝对路径并令同步端回退默认远端图。
  Map<String, Object?>? toSyncJson();

  /// 从本地或同步 JSON 还原 [ArtworkRef]；若结构非法或为空则返回 `null`。
  static ArtworkRef? tryFromJson(Map<String, Object?>? json) {
    if (json == null) return null;
    final kind = json['kind'] as String?;
    final locked = json['locked'] == true;
    switch (kind) {
      case 'remote':
        final rawSource = json['source'] as String?;
        final uri = (json['uri'] as String?)?.trim() ?? '';
        if (rawSource == null || uri.isEmpty) return null;
        final source = _tryParseSource(rawSource);
        if (source == null) return null;
        return RemoteArtworkRef(source: source, uri: uri, locked: locked);
      case 'localCustom':
        final localPath = (json['localPath'] as String?)?.trim() ?? '';
        if (localPath.isEmpty) return null;
        return LocalCustomArtworkRef(localPath: localPath, locked: locked);
      default:
        return null;
    }
  }

  static ArtworkSource? _tryParseSource(String raw) {
    for (final item in ArtworkSource.values) {
      if (item.name == raw) return item;
    }
    return null;
  }
}

/// 远程来源艺术图引用（支持按轻量引用跨设备同步并自动按需拉取缓存）。
final class RemoteArtworkRef extends ArtworkRef {
  /// 创建远程来源艺术图引用。
  const RemoteArtworkRef({
    required this.source,
    required this.uri,
    super.locked = false,
  });

  /// 远端图片提供方。
  final ArtworkSource source;

  /// 远端相对路径（如 TMDB `/abc.jpg`）或完整 URL。
  final String uri;

  /// 返回修改锁定态或地址后的副本。
  RemoteArtworkRef copyWith({
    ArtworkSource? source,
    String? uri,
    bool? locked,
  }) {
    return RemoteArtworkRef(
      source: source ?? this.source,
      uri: uri ?? this.uri,
      locked: locked ?? this.locked,
    );
  }

  @override
  Map<String, Object?> toLocalJson() => <String, Object?>{
    'kind': 'remote',
    'source': source.name,
    'uri': uri,
    'locked': locked,
  };

  @override
  Map<String, Object?> toSyncJson() => toLocalJson();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RemoteArtworkRef &&
          source == other.source &&
          uri == other.uri &&
          locked == other.locked;

  @override
  int get hashCode => Object.hash(source, uri, locked);

  @override
  String toString() =>
      'RemoteArtworkRef(source: ${source.name}, uri: $uri, locked: $locked)';
}

/// 本机自定义图片引用（仅本机有效，绝不参与跨设备路径同步）。
final class LocalCustomArtworkRef extends ArtworkRef {
  /// 创建本机自定义图片引用（默认视为人工锁定）。
  const LocalCustomArtworkRef({required this.localPath, super.locked = true});

  /// 本机图片路径（相对便携根目录或本机文件路径）。
  final String localPath;

  /// 返回修改路径或锁定态后的副本。
  LocalCustomArtworkRef copyWith({String? localPath, bool? locked}) {
    return LocalCustomArtworkRef(
      localPath: localPath ?? this.localPath,
      locked: locked ?? this.locked,
    );
  }

  @override
  Map<String, Object?> toLocalJson() => <String, Object?>{
    'kind': 'localCustom',
    'localPath': localPath,
    'locked': locked,
  };

  @override
  Map<String, Object?>? toSyncJson() => null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LocalCustomArtworkRef &&
          localPath == other.localPath &&
          locked == other.locked;

  @override
  int get hashCode => Object.hash(localPath, locked);

  @override
  String toString() =>
      'LocalCustomArtworkRef(localPath: $localPath, locked: $locked)';
}
