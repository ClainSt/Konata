import 'package:konata_contracts/konata_contracts.dart';

/// 作品艺术图路径与强类型 [ArtworkRef] 的双向映射工具。
///
/// 统一处理 TMDB 相对路径/URL、Bangumi 封面 URL、Fanart 高清图 URL
/// 以及本机自定义图片或文件夹封面到 `konata_contracts` 契约引用的无损转换。
abstract final class ArtworkRefCodec {
  /// 当用户仅锁定空槽位（例如锁定无图/纯文字徽标兜底）时写入的本机占位路径标识。
  static const String lockedEmptySentinel = 'konata://locked-empty';

  /// 将存储/刮削阶段的字符串路径与锁定标记编码为 [ArtworkRef]。
  static ArtworkRef? fromPath(
    String? path, {
    bool locked = false,
    ArtworkSource? explicitSource,
  }) {
    final trimmed = path?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      if (!locked) return null;
      return const ArtworkRef.localCustom(
        localPath: lockedEmptySentinel,
        locked: true,
      );
    }
    if (explicitSource != null && !_isLocalCoverScheme(trimmed)) {
      return ArtworkRef.remote(
        source: explicitSource,
        uri: trimmed,
        locked: locked,
      );
    }
    final inferred = inferRemoteSource(trimmed);
    if (inferred != null) {
      return ArtworkRef.remote(
        source: inferred,
        uri: trimmed,
        locked: locked,
      );
    }
    return ArtworkRef.localCustom(localPath: trimmed, locked: locked);
  }

  /// 从 [ArtworkRef] 提取对应的远程 URI 或本机自定义路径；锁定空槽位占位还原为 `null`。
  static String? toPath(ArtworkRef? ref) {
    return switch (ref) {
      RemoteArtworkRef(:final uri) => uri,
      LocalCustomArtworkRef(:final localPath) =>
        localPath == lockedEmptySentinel ? null : localPath,
      null => null,
    };
  }

  /// 从各槽位引用分别还原兼容字段（路径与锁定开关）。
  static ({
    String? posterPath,
    bool posterLocked,
    String? backdropPath,
    bool backdropLocked,
    String? logoPath,
    bool logoLocked,
  }) unpackWorkArtworks({
    ArtworkRef? posterRef,
    ArtworkRef? backdropRef,
    ArtworkRef? logoRef,
  }) {
    return (
      posterPath: toPath(posterRef),
      posterLocked: posterRef?.locked ?? false,
      backdropPath: toPath(backdropRef),
      backdropLocked: backdropRef?.locked ?? false,
      logoPath: toPath(logoRef),
      logoLocked: logoRef?.locked ?? false,
    );
  }

  /// 根据路径前缀或域名推断远程艺术图来源；非远端路径返回 `null`。
  static ArtworkSource? inferRemoteSource(String path) {
    final trimmed = path.trim();
    if (trimmed.isEmpty || _isLocalCoverScheme(trimmed)) {
      return null;
    }
    final lower = trimmed.toLowerCase();
    if (lower.startsWith('http://') || lower.startsWith('https://')) {
      final host = Uri.tryParse(trimmed)?.host.toLowerCase() ?? '';
      if (host.contains('fanart.tv')) {
        return ArtworkSource.fanart;
      }
      if (host.contains('bgm.tv') || host.contains('bangumi.tv')) {
        return ArtworkSource.bangumi;
      }
      return ArtworkSource.tmdb;
    }
    if (trimmed.startsWith('/') &&
        !trimmed.startsWith('//') &&
        !trimmed.startsWith('/Users/') &&
        !trimmed.startsWith('/home/') &&
        !trimmed.startsWith('/storage/') &&
        !trimmed.startsWith('/var/') &&
        !trimmed.startsWith('/tmp/') &&
        trimmed.indexOf('/', 1) == -1) {
      return ArtworkSource.tmdb;
    }
    return null;
  }

  static bool _isLocalCoverScheme(String value) {
    return value.toLowerCase().startsWith('cover://');
  }
}
