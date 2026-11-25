import '../ports/read_query_ports.dart';
import '../value_objects/domain_enums.dart';

/// 远程或本地目录项强类型描述。
class RemoteEntry {
  /// 创建目录项实例。
  const RemoteEntry({
    required this.name,
    required this.relativePath,
    required this.isDirectory,
    this.size = 0,
    this.modifiedAt,
    this.etag,
    this.remoteFileId,
  });

  /// 文件或子目录名称。
  final String name;

  /// 相对于媒体源根目录的规范化路径（以正斜杠分隔）。
  final String relativePath;

  /// 是否为目录。
  final bool isDirectory;

  /// 文件字节大小（目录为 0）。
  final int size;

  /// 最后修改时间（若协议提供）。
  final DateTime? modifiedAt;

  /// 协议返回的资源版本标识。
  final String? etag;

  /// 服务端稳定文件标识，不包含令牌或下载地址。
  final String? remoteFileId;

  /// 生成用于缓存版本隔离的真实源验证器（优先版本标签，其次修改时间）。
  String? get cacheValidator {
    final rawEtag = etag?.trim();
    if (rawEtag != null && rawEtag.isNotEmpty) {
      return rawEtag;
    }
    final mtime = modifiedAt;
    if (mtime != null) {
      return 'mtime:${mtime.toUtc().microsecondsSinceEpoch}';
    }
    return null;
  }
}

/// 只读虚拟文件系统抽象接口（隔离本地磁盘、WebDAV 与 SMB 协议细节）。
abstract interface class MediaSourceGateway {
  /// 列出指定相对目录下的直接子项（非递归）。
  Future<List<RemoteEntry>> listDirectory(String relativePath);

  /// 读取小文本文件，限制最大读取字节防止误读大文件。
  Future<String?> readTextFile(
    String relativePath, {
    int maxBytes = 256 * 1024,
  });

  /// 测试媒体源连通性，连通成功返回空，失败返回可读错误说明。
  Future<String?> testConnection();

  /// 释放底层网络连接或会话资源。
  Future<void> close();
}

/// 远程流网桥唯一重试预算常量（严禁在多层同时叠加重试）。
abstract final class SourceRetryPolicy {
  /// 单次分块读取允许的最大重试次数。
  static const int maxRetries = 2;

  /// 单次分块续传允许消耗的最大墙钟时间上限。
  static const Duration maxWallClockBudget = Duration(seconds: 8);
}

/// 携带强验证器与范围响应元数据的字节流封装。
class ValidatedByteRangeStream {
  /// 创建强验证字节范围流。
  const ValidatedByteRangeStream({
    required this.stream,
    required this.start,
    this.endInclusive,
    this.totalLength,
    this.strongValidator,
    this.isPartialContent = true,
  });

  /// 底层渐进式字节流。
  final Stream<List<int>> stream;

  /// 服务端实际返回范围起点（含）。
  final int start;

  /// 服务端实际返回范围终点（含，未知时可空）。
  final int? endInclusive;

  /// 服务端宣告的文件总字节数（未知时可空）。
  final int? totalLength;

  /// 服务端强验证器（用于断流续传一致性核验）。
  final String? strongValidator;

  /// 响应状态是否为部分内容分片。
  final bool isPartialContent;
}

/// 上游认证终态拒绝异常（重试后仍拒绝时立即终止，严禁空转重试）。
class TerminalSourceAuthException implements Exception {
  /// 创建认证终态异常。
  const TerminalSourceAuthException(
    this.message, {
    required this.statusCode,
    this.uri,
  });

  /// 简体中文故障描述。
  final String message;

  /// 关联请求地址。
  final Uri? uri;

  /// HTTP 状态码（401 或 403）。
  final int statusCode;

  @override
  String toString() => 'TerminalSourceAuthException($statusCode): $message';
}

/// 上游分块续传不一致异常（遇到整包响应、起点错位或版本变更时立即熔断）。
class UpstreamRangeMismatchException implements Exception {
  /// 创建续传一致性失配异常。
  const UpstreamRangeMismatchException(this.message, {this.uri});

  /// 简体中文故障描述。
  final String message;

  /// 关联请求地址。
  final Uri? uri;

  @override
  String toString() => 'UpstreamRangeMismatchException: $message';
}

/// 支持按字节范围流式读取的媒体源网关扩展契约。
abstract interface class ByteRangeReadableGateway {
  /// 探测目标文件的精确字节总长度；若未知返回空。
  Future<int?> probeFileLength(String relativePath);

  /// 打开指定字节区间的只读字节流（起点与终点均含，未传终点时读至文件末尾）。
  Future<Stream<List<int>>> openByteRange(
    String relativePath, {
    required int start,
    int? endInclusive,
  });

  /// 释放底层网络连接或会话资源。
  Future<void> close();
}

/// 支持同时探测文件精确长度与真实源版本验证器的媒体源网关扩展契约。
abstract interface class FileValidatorProbeGateway
    implements ByteRangeReadableGateway {
  /// 单次往返探测目标文件的字节总长度及真实版本验证器。
  Future<({int? length, String? validator})> probeFileMetadata(
    String relativePath,
  );
}

/// 支持强验证器一致性断流续传的字节范围网关扩展契约。
abstract interface class ValidatedByteRangeGateway
    implements ByteRangeReadableGateway {
  /// 打开带强验证器核验的字节范围流；传入预期验证器时强制校验版本一致。
  Future<ValidatedByteRangeStream> openValidatedByteRange(
    String relativePath, {
    required int start,
    int? endInclusive,
    String? expectedStrongValidator,
  });
}

/// 有时效性的文件直链；鉴权头仅用于该次请求。
final class RenewableLink {
  const RenewableLink(this.uri, {this.headers = const {}});

  final Uri uri;
  final Map<String, String> headers;
}

/// 以文件标识刷新下载地址，不改变文件身份或总大小。
abstract interface class RenewableUpstream {
  int get totalSize;
  String? get strongValidator;
  Future<RenewableLink> current();
  Future<RenewableLink> renew();
}

/// 云盘网关标识；扫描调度按严格串行处理。
abstract interface class CloudDriveGateway
    implements
        MediaSourceGateway,
        ValidatedByteRangeGateway,
        FileValidatorProbeGateway {}

/// 媒体源连接与读取故障精确分类。
enum SourceAccessProblemKind {
  /// 用户名或密码认证失败。
  authentication,

  /// 权限不足。
  permission,

  /// 路径或共享名不存在。
  path,

  /// 网络连接或响应超时。
  timeout,

  /// 网络不可达（连接拒绝、主机不可达或域名解析失败）。
  network,

  /// 安全传输证书或协议握手失败。
  tls,

  /// 远程网盘或网关触发频控限流。
  rateLimited,

  /// 其他未知访问异常。
  unknown,
}

/// 远程网盘或网关返回频控限流时抛出的强类型异常。
class SourceRateLimitException implements Exception {
  /// 创建网盘限流异常实例。
  const SourceRateLimitException({
    required this.statusCode,
    required this.message,
    this.retryAfter,
    this.uri,
  });

  /// 服务端返回的 HTTP 状态码。
  final int statusCode;

  /// 中文可读故障说明。
  final String message;

  /// 服务端建议的冷却等待时长。
  final Duration? retryAfter;

  /// 触发限流的目标请求地址。
  final Uri? uri;

  @override
  String toString() => message;
}

/// 携带中文友好说明的媒体源访问异常。
class SourceAccessException implements Exception {
  /// 创建强类型媒体源访问异常。
  const SourceAccessException(this.kind, this.message, [this.cause]);

  /// 精确故障分类。
  final SourceAccessProblemKind kind;

  /// 中文错误说明。
  final String message;

  /// 原始异常。
  final Object? cause;

  @override
  String toString() => message;
}

/// 账号风控或验证码拦截。必须停止自动调用，等待用户重新授权。
final class RiskControlled extends SourceAccessException {
  const RiskControlled()
    : super(SourceAccessProblemKind.permission, '云盘风控已停止自动访问，请完成官方授权后重试');
}

/// 根据媒体源只读视图构建只读网关的抽象工厂端口。
abstract interface class MediaSourceGatewayFactoryPort {
  /// 为指定媒体源创建并初始化对应的只读网关。
  Future<MediaSourceGateway> create(
    MediaSourceView source, {
    String? passwordOverride,
    bool clearPassword = false,
  });
}

/// 经同卷校验并原子落盘的原始外挂字幕缓存记录。
class MaterializedSubtitleRecord {
  /// 创建原始字幕缓存记录。
  const MaterializedSubtitleRecord({
    required this.relativePath,
    required this.localFilePath,
    required this.sourceSha1,
    required this.byteLength,
    required this.cacheKey,
    this.validator = '',
  });

  /// 媒体源中的原始相对路径。
  final String relativePath;

  /// 本地应用便携缓存目录中的原子落盘绝对路径。
  final String localFilePath;

  /// 原始字幕字节流的校验摘要。
  final String sourceSha1;

  /// 校验后的实际字节长度。
  final int byteLength;

  /// 绑定媒体源、规范相对路径与版本验证器的缓存键。
  final String cacheKey;

  /// 源版本验证器。
  final String validator;
}

/// 虚拟专辑远程音频文件输入描述（供同源分轨目录与播放列表共用）。
class VirtualAlbumAudioEntry {
  /// 创建虚拟专辑远程音频条目。
  const VirtualAlbumAudioEntry({
    required this.entryFileName,
    required this.relativePath,
    this.knownLength,
    this.title = '',
    this.performer = '',
    this.durationSeconds = -1,
  });

  /// 挂载在虚拟目录下的文件名。
  final String entryFileName;

  /// 在上游远程源中的真实相对路径。
  final String relativePath;

  /// 已知文件字节长度（可选，省去额外探测）。
  final int? knownLength;

  /// 曲目展示标题。
  final String title;

  /// 曲目演唱者。
  final String performer;

  /// 曲目整秒时长。
  final int durationSeconds;
}

/// 虚拟专辑目录注册结果（含主清单地址与首条音频流兜底地址）。
class VirtualAlbumRegistration {
  /// 创建虚拟专辑注册结果。
  const VirtualAlbumRegistration({
    required this.albumToken,
    required this.manifestUrl,
    required this.primaryAudioUrl,
    required this.audioUrls,
  });

  /// 虚拟专辑会话令牌。
  final String albumToken;

  /// 主清单地址。
  final Uri manifestUrl;

  /// 首条物理音频流直达地址。
  final Uri primaryAudioUrl;

  /// 虚拟目录下按序排列的全部音频流地址列表。
  final List<Uri> audioUrls;
}

/// 本地安全回环流媒体网桥抽象端口（由 `engine_sources` 的 `LocalStreamBridge` 实现）。
abstract interface class LocalStreamBridgePort {
  /// 当前监听端口号（未启动时返回空）。
  int? get port;

  /// 当前仍处于注册状态的流会话总数。
  int get activeSessionCount;

  /// 注册远程媒体的本地流会话并返回会话令牌与回环地址。
  Future<({String token, Uri url})> registerSession({
    required ByteRangeReadableGateway gateway,
    required String relativePath,
    required String fileName,
    int? knownLength,
    bool ownsGateway = false,
    MediaSourceKind sourceKind = MediaSourceKind.webdav,
  });

  /// 静默预热指定流会话的片头与片尾元数据区间。
  Future<bool> prewarmSessionMetadata(
    String token, {
    int headBytes = 1024 * 1024,
    int tailBytes = 512 * 1024,
  });

  /// 注销单个流会话并按需释放关联网关。
  Future<void> unregisterSession(String token);

  /// 注册远程整轨与分轨清单的同源虚拟目录会话。
  Future<VirtualAlbumRegistration> registerCueAlbumSession({
    required ByteRangeReadableGateway gateway,
    required String normalizedCueText,
    required List<VirtualAlbumAudioEntry> audioEntries,
    bool ownsGateway = true,
    MediaSourceKind sourceKind = MediaSourceKind.webdav,
  });

  /// 注册远程多曲目播放列表虚拟会话。
  Future<VirtualAlbumRegistration> registerPlaylistM3u8Session({
    required ByteRangeReadableGateway gateway,
    required List<VirtualAlbumAudioEntry> audioEntries,
    bool ownsGateway = true,
    MediaSourceKind sourceKind = MediaSourceKind.webdav,
  });

  /// 注销虚拟专辑会话并释放关联网关。
  Future<void> unregisterAlbumSession(String albumToken);

  /// 纯本地零网络检查已缓存落盘的外挂字幕路径。
  Future<List<String>> resolveExistingCachedSubtitles({
    required String workId,
    required List<String> subtitleRelativePaths,
    String? sourceId,
    Map<String, String>? validatorsByPath,
  });

  /// 将远程外挂字幕并发拉取并经同卷校验原子落盘。
  Future<List<String>> materializeRemoteSubtitles({
    required ByteRangeReadableGateway gateway,
    required String workId,
    required List<String> subtitleRelativePaths,
    String? sourceId,
    Map<String, String>? validatorsByPath,
  });

  /// 拉取并落盘远程外挂字幕，同时返回完整校验记录。
  Future<List<MaterializedSubtitleRecord>> materializeRemoteSubtitleRecords({
    required ByteRangeReadableGateway gateway,
    required String workId,
    required List<String> subtitleRelativePaths,
    String? sourceId,
    Map<String, String>? validatorsByPath,
  });

  /// 查询最近一次捕获的上游访问故障中文说明。
  String? describeLastError({String? token, String? relativePath});

  /// 查询最近一次捕获的上游故障分类。
  SourceAccessProblemKind? lastErrorKind({String? token, String? relativePath});

  /// 回收超过空闲阈值且无活跃传输流的历史会话。
  Future<int> pruneIdleSessions({Duration? maxIdle, DateTime? now});

  /// 停止回环服务器并释放全部会话资源。
  Future<void> close();
}

/// 单个目录（含字幕与音轨子目录）的内存索引快照。
class SubtitleDirectorySnapshot {
  /// 创建目录索引快照。
  const SubtitleDirectorySnapshot({
    required this.siblingPaths,
    required this.cachedAt,
    required this.hasUnscannedSubdirs,
    required this.incompleteForSimplified,
    this.scannedSubdirCount = 0,
    this.unscannedSubdirs = const <String>[],
    this.validatorsByPath = const <String, String>{},
  });

  /// 同级及已扫描子目录下的全部文件相对路径。
  final List<String> siblingPaths;

  /// 快照写入时间。
  final DateTime cachedAt;

  /// 是否存在超出扫描配额而尚未深入的子目录。
  final bool hasUnscannedSubdirs;

  /// 若存在未扫子目录且当前仅命中非简中字幕，置为真以防写入假阴性负缓存。
  final bool incompleteForSimplified;

  /// 实际已扫描的子目录数量。
  final int scannedSubdirCount;

  /// 尚未深入扫描的剩余候选子目录相对路径列表。
  final List<String> unscannedSubdirs;

  /// 各相对路径对应的真实源版本验证器。
  final Map<String, String> validatorsByPath;
}

/// 详情页同级字幕与外挂音轨目录静默预热端口（由 `engine_sources` 实现）。
abstract interface class SubtitleDirectoryWarmupPort {
  /// 查询内存索引表中未过期的目录快照。
  SubtitleDirectorySnapshot? lookupDirectorySnapshot(
    String sourceId,
    String dirRelativePath,
  );

  /// 预热单个远程目录并写入内存索引表。
  Future<SubtitleDirectorySnapshot?> warmupDirectory({
    required MediaSourceView source,
    required String dirRelativePath,
    int? expectedGeneration,
  });

  /// 递增预热代数以取消过时的在途预热任务。
  void cancelPending();
}
