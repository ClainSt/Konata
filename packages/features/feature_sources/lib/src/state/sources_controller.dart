import 'dart:async';

import 'package:engine_scraping/engine_scraping.dart';
import 'package:engine_sources/engine_sources.dart';
import 'package:flutter/foundation.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

import 'source_scope_prefs.dart';

/// 识别旧版从光鸭账号地址提取的自动名称。
bool isLegacyCloudSourceLabel(MediaSource source) =>
    source.kind == MediaSourceKind.cloudDrive &&
    RegExp(r'^gya_[0-9a-f]{64}$').hasMatch(source.label) &&
    Uri.tryParse(source.location)?.host == source.label;

/// 按已占用名称分配最小可用编号。
String nextSourceLabel(MediaSourceKind kind, Set<String> used) {
  final base = defaultSourceLabel(kind);
  if (!used.contains(base)) return base;
  for (var i = 2; ; i++) {
    final label = '$base$i';
    if (!used.contains(label)) return label;
  }
}

/// 旧自动名称仅在展示层替换，不触碰源标识或授权信息。
List<MediaSource> friendlySourceLabels(List<MediaSource> sources) {
  final used = sources
      .where((s) => !isLegacyCloudSourceLabel(s))
      .map((s) => s.label)
      .toSet();
  final aliases = <String, String>{};
  final legacy = sources.where(isLegacyCloudSourceLabel).toList()
    ..sort((a, b) => a.id.compareTo(b.id));
  for (final source in legacy) {
    final label = nextSourceLabel(source.kind, used);
    used.add(label);
    aliases[source.id] = label;
  }
  return [
    for (final source in sources)
      if (aliases.containsKey(source.id))
        source.copyWith(label: aliases[source.id])
      else
        source,
  ];
}

/// 媒体源保存或编辑操作结果。
@immutable
class SourceActionResult {
  /// 构造媒体源操作结果。
  const SourceActionResult({
    required this.success,
    this.source,
    this.errorMessage,
  });

  /// 操作是否成功完成。
  final bool success;

  /// 成功保存后的媒体源实体快照。
  final MediaSource? source;

  /// 失败时展示给用户的中文错误原因。
  final String? errorMessage;
}

/// 媒体源连通性测试结果。
@immutable
class SourceTestResult {
  /// 构造连通性测试结果。
  const SourceTestResult({required this.success, required this.message});

  /// 是否成功连上媒体源根目录。
  final bool success;

  /// 中文结果摘要或诊断提示。
  final String message;
}

/// 单个媒体源在本地媒体库中的作品与物理文件统计摘要。
@immutable
class SourceLibraryStats {
  /// 构造媒体源入库统计摘要。
  const SourceLibraryStats({
    this.workCount = 0,
    this.videoCount = 0,
    this.totalFileCount = 0,
    this.reviewCount = 0,
  });

  /// 该媒体源关联的未删除作品总数。
  final int workCount;

  /// 该媒体源下正片/特典视频文件数。
  final int videoCount;

  /// 该媒体源下全部已索引物理文件数（含音频与扫图）。
  final int totalFileCount;

  /// 该媒体源下当前待复核作品数。
  final int reviewCount;

  /// 是否已有任何入库记录。
  bool get hasAnyIndexed => workCount > 0 || totalFileCount > 0;
}

/// 媒体源核心业务控制器（零 `Riverpod` 纯构造注入状态机）。
///
/// 职责边界：
/// - 负责 Local / WebDAV / SMB 媒体源增删改查、地址格式校验与重名校验；
/// - 敏感密码仅通过 `SourceCredentialStore` 写入 `SecureStoragePort`，绝不落入 SQLite 或日志；
/// - 移除媒体源仅在本地数据库写软删除墓碑并清理孤立索引，绝不删除用户物理媒体文件；
/// - 变更后通过 `DomainEventBus` 发布 `MediaSourceChangedEvent` 与受影响的 `LibraryWorkChangedEvent`。
class SourcesController extends ChangeNotifier {
  /// 创建媒体源控制器。
  SourcesController({
    required this.databases,
    required this.credentialStore,
    required this.gatewayFactory,
    required this.eventBus,
    this.scopedPrefs,
    this.diagnosticLog,
    this.sourceDeviceId = '',
    int Function()? nowMs,
  }) : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch),
       _repository = StorageScrapeRepository(
         databases,
         sourceDeviceId: sourceDeviceId,
         nowMs: nowMs,
       );

  /// 三库合一存储句柄。
  final KonataDatabaseBundle databases;

  /// 受保护的凭据读写仓储。
  final SourceCredentialStore credentialStore;

  /// 跨协议媒体源只读网关工厂。
  final MediaSourceGatewayFactoryPort gatewayFactory;

  /// 跨模块领域事件总线。
  final DomainEventBus eventBus;

  /// 可选分作用域配置存储（持久化子目录作用域与最近扫描时间）。
  final ScopedPrefsStore? scopedPrefs;

  /// 可选诊断日志端口。
  final DiagnosticLogPort? diagnosticLog;

  /// 当前设备标识，写入数据库软删除与变更追踪元数据。
  final String sourceDeviceId;

  final int Function() _nowMs;
  final StorageScrapeRepository _repository;

  static int _idSequence = 0;
  static final RegExp _trailingSlashes = RegExp(r'/+$');
  static final RegExp _leadingSlashes = RegExp(r'^/+');
  static final RegExp _digitsPattern = RegExp(r'\d+');

  /// 持续监听当前未删除的媒体源列表（按创建时间升序）。
  Stream<List<MediaSource>> watchSources() {
    return databases.library.mediaSources.watchAll().asyncMap(
      (_) => _repository.getMediaSources(),
    );
  }

  /// 实时监听各媒体源关联的作品数、视频数与待复核计数统计快照。
  Stream<Map<String, SourceLibraryStats>> watchSourceStats() {
    return databases.library.engine.watchQuery<Map<String, SourceLibraryStats>>(
      tables: const <String>{MediaVariantsSchema.table, WorksSchema.table},
      query: (db) {
        final rs = db.select(
          '''
SELECT
  mv.${MediaVariantsSchema.colSourceId} AS source_id,
  COUNT(DISTINCT mv.${MediaVariantsSchema.colWorkId}) AS work_count,
  COUNT(DISTINCT CASE
    WHEN w.${WorksSchema.colScrapeStatus} = ? AND w.${WorksSchema.colIsHidden} = 0
    THEN mv.${MediaVariantsSchema.colWorkId}
  END) AS review_count,
  SUM(CASE WHEN mv.${MediaVariantsSchema.colAssetKind} = ? THEN 1 ELSE 0 END) AS video_count,
  COUNT(*) AS total_file_count
FROM ${MediaVariantsSchema.table} mv
INNER JOIN ${WorksSchema.table} w
  ON w.${WorksSchema.colId} = mv.${MediaVariantsSchema.colWorkId}
WHERE mv.${MediaVariantsSchema.colDeletedAtMs} IS NULL
  AND w.${WorksSchema.colDeletedAtMs} IS NULL
GROUP BY mv.${MediaVariantsSchema.colSourceId};
''',
          <Object?>[ScrapeStatus.needsReview.name, AssetKind.video.name],
        );
        final map = <String, SourceLibraryStats>{};
        for (final row in rs) {
          final sid = row['source_id'] as String?;
          if (sid == null || sid.isEmpty) continue;
          map[sid] = SourceLibraryStats(
            workCount: (row['work_count'] as int?) ?? 0,
            reviewCount: (row['review_count'] as int?) ?? 0,
            videoCount: (row['video_count'] as int?) ?? 0,
            totalFileCount: (row['total_file_count'] as int?) ?? 0,
          );
        }
        return Map<String, SourceLibraryStats>.unmodifiable(map);
      },
    );
  }

  /// 一次性查询全部有效媒体源。
  Future<List<MediaSource>> listSources() {
    return _repository.getMediaSources();
  }

  /// 按 ID 查找媒体源。
  Future<MediaSource?> findSource(String sourceId) {
    return _repository.findSourceById(sourceId);
  }

  /// 持续监听指定媒体源下的忽略相对目录列表。
  Stream<List<String>> watchIgnoredFolders(String sourceId) {
    return databases.library.ignoredFolders
        .watchBySource(SourceId.trusted(sourceId))
        .map(
          (records) => List<String>.unmodifiable([
            for (final rec in records) rec.relativePath,
          ]),
        );
  }

  /// 查询指定媒体源下全部已忽略相对目录。
  Future<List<String>> listIgnoredFolders(String sourceId) {
    return _repository.getIgnoredFolders(sourceId);
  }

  /// 读取指定媒体源最近一次扫库完成时间。
  DateTime? readLastScannedAt(String sourceId) {
    return SourceScopePrefs.readLastScannedAt(scopedPrefs, sourceId);
  }

  /// 读取媒体源当前是否已保存过敏感密码（以及密码值，供编辑器保留状态与连通测试使用）。
  Future<String?> readSavedPassword(String sourceId) {
    return credentialStore.readPassword(sourceId);
  }

  /// 校验并归一化用户输入的本地路径或远程服务地址。
  ValidatedSourceLocation validateLocation(
    MediaSourceKind kind,
    String rawLocation,
  ) {
    return SourceLocationValidator.validate(kind, rawLocation);
  }

  /// 新建或编辑保存一条媒体源记录，并同步维护安全凭据与领域事件。
  Future<SourceActionResult> saveSource({
    String? existingId,
    required MediaSourceKind kind,
    required String label,
    required String location,
    String? username,
    String? password,
    bool clearPassword = false,
  }) async {
    var trimmedLabel = label.trim();

    final validated = SourceLocationValidator.validate(kind, location);
    if (!validated.isValid) {
      return SourceActionResult(
        success: false,
        errorMessage: validated.errorMessage ?? '媒体源地址格式无效',
      );
    }

    final normalizedLoc = _normalizeComparableLocation(
      kind,
      validated.normalizedLocation,
    );
    final existingSources = await _repository.getMediaSources();
    if (trimmedLabel.isEmpty) {
      final friendly = friendlySourceLabels(existingSources);
      trimmedLabel = nextSourceLabel(kind, {
        for (final item in friendly)
          if (item.id != existingId) item.label,
      });
    }
    for (final item in existingSources) {
      if (item.id == existingId) continue;
      if (item.kind == kind &&
          _normalizeComparableLocation(item.kind, item.location) ==
              normalizedLoc) {
        return SourceActionResult(
          success: false,
          errorMessage: '已存在相同地址的媒体源「${item.label}」',
        );
      }
    }

    final existing = existingId == null
        ? null
        : await _repository.findSourceById(existingId);
    final id =
        existing?.id ??
        existingId ??
        'src_${kind.name}_${_nowMs()}_${++_idSequence}';

    if (kind == MediaSourceKind.cloudDrive ||
        existing?.kind == MediaSourceKind.cloudDrive) {
      if (existing != null &&
          (existing.kind != kind ||
              _normalizeComparableLocation(existing.kind, existing.location) !=
                  normalizedLoc)) {
        return const SourceActionResult(
          success: false,
          errorMessage: '云盘媒体源的账号与根目录不可更换，请添加独立媒体源',
        );
      }
      if (existing == null) {
        final result = await testConnection(
          kind: kind,
          location: validated.normalizedLocation,
        );
        if (!result.success) {
          return SourceActionResult(
            success: false,
            errorMessage: result.message,
          );
        }
      }
    }

    final cleanUsername = _cleanOptionalText(username);
    final entity = MediaSource(
      id: id,
      kind: kind,
      label: trimmedLabel,
      location: validated.normalizedLocation,
      username:
          kind == MediaSourceKind.local || kind == MediaSourceKind.cloudDrive
          ? null
          : cleanUsername,
      createdAt:
          existing?.createdAt ?? DateTime.fromMillisecondsSinceEpoch(_nowMs()),
    );

    try {
      if (kind == MediaSourceKind.local ||
          kind == MediaSourceKind.cloudDrive ||
          clearPassword) {
        await credentialStore.deletePassword(id);
      } else if (password != null && password.isNotEmpty) {
        await credentialStore.savePassword(id, password);
      }

      await _repository.upsertMediaSource(entity);
      eventBus.publish(
        MediaSourceChangedEvent(
          sourceId: SourceId.trusted(id),
          reason: existing == null ? 'created' : 'updated',
          occurredAtMs: _nowMs(),
        ),
      );
      notifyListeners();
      return SourceActionResult(success: true, source: entity);
    } catch (error) {
      final safeError = DiagnosticTextSanitizer.redactSecrets('$error');
      diagnosticLog?.logError(
        subsystem: DiagnosticSubsystem.source,
        code: 'source_save_failed',
        message: '保存媒体源失败: $safeError',
        error: error,
        source: 'SourcesController.saveSource',
      );
      return SourceActionResult(
        success: false,
        errorMessage: '保存媒体源失败：$safeError',
      );
    }
  }

  /// 添加一个在后续扫库中跳过的相对目录路径。
  Future<void> addIgnoredFolder(String sourceId, String relativePath) async {
    final clean = _normalizeRelativePath(relativePath);
    if (clean.isEmpty) return;
    await _repository.addIgnoredFolder(sourceId, clean);
    eventBus.publish(
      MediaSourceChangedEvent(
        sourceId: SourceId.trusted(sourceId),
        reason: 'ignored_folder_added',
        occurredAtMs: _nowMs(),
      ),
    );
    notifyListeners();
  }

  /// 恢复一个此前被忽略的相对目录路径（采用软删除墓碑标记）。
  Future<void> removeIgnoredFolder(String sourceId, String relativePath) async {
    final clean = _normalizeRelativePath(relativePath);
    if (clean.isEmpty) return;
    databases.library.ignoredFolders.softDelete(
      '$sourceId::$clean',
      deletedAtMs: _nowMs(),
      sourceDeviceId: sourceDeviceId,
    );
    eventBus.publish(
      MediaSourceChangedEvent(
        sourceId: SourceId.trusted(sourceId),
        reason: 'ignored_folder_removed',
        occurredAtMs: _nowMs(),
      ),
    );
    notifyListeners();
  }

  /// 测试目标媒体源配置是否可正常连接（编辑状态下支持沿用已存密码）。
  Future<SourceTestResult> testConnection({
    String? sourceId,
    required MediaSourceKind kind,
    required String location,
    String? username,
    String? password,
    bool clearPassword = false,
  }) async {
    final validated = SourceLocationValidator.validate(kind, location);
    if (!validated.isValid) {
      return SourceTestResult(
        success: false,
        message: validated.errorMessage ?? '地址格式无效',
      );
    }

    final view = MediaSourceView(
      id: SourceId.trusted(sourceId ?? 'probe_${_nowMs()}'),
      kind: kind,
      label: '连通性测试',
      location: validated.normalizedLocation,
      username:
          kind == MediaSourceKind.local || kind == MediaSourceKind.cloudDrive
          ? null
          : _cleanOptionalText(username),
    );

    try {
      String? passwordOverride;
      if (kind != MediaSourceKind.local &&
          kind != MediaSourceKind.cloudDrive &&
          !clearPassword) {
        if (password != null && password.isNotEmpty) {
          passwordOverride = password;
        } else if (sourceId != null && sourceId.isNotEmpty) {
          passwordOverride = await credentialStore.readPassword(sourceId);
        }
      }

      final gateway = await gatewayFactory.create(
        view,
        passwordOverride: passwordOverride,
        clearPassword: clearPassword,
      );
      try {
        final failure = await gateway.testConnection().timeout(
          const Duration(seconds: 12),
        );
        if (failure == null || failure.trim().isEmpty) {
          return const SourceTestResult(
            success: true,
            message: '连接成功，可正常读取媒体源目录',
          );
        }
        return SourceTestResult(
          success: false,
          message: DiagnosticTextSanitizer.redactSecrets(failure),
        );
      } finally {
        await gateway.close();
      }
    } catch (error) {
      final safeError = DiagnosticTextSanitizer.redactSecrets('$error');
      return SourceTestResult(success: false, message: '连接失败：$safeError');
    }
  }

  /// 列出指定媒体源相对路径下的条目列表（默认仅子目录；开启 [includeFiles] 时目录优先返回）。
  Future<List<RemoteEntry>> listDirectory({
    String? sourceId,
    required MediaSourceKind kind,
    required String location,
    String? username,
    String? password,
    bool clearPassword = false,
    String relativePath = '',
    bool includeFiles = false,
  }) async {
    final session = await openDirectoryBrowseSession(
      sourceId: sourceId,
      kind: kind,
      location: location,
      username: username,
      password: password,
      clearPassword: clearPassword,
    );
    try {
      return await session.listDirectory(
        relativePath,
        includeFiles: includeFiles,
      );
    } finally {
      await session.close();
    }
  }

  /// 打开由调用方负责关闭的目录浏览会话；仅供交互式浏览，扫库仍独立创建网关。
  Future<SourceDirectoryBrowseSession> openDirectoryBrowseSession({
    String? sourceId,
    required MediaSourceKind kind,
    required String location,
    String? username,
    String? password,
    bool clearPassword = false,
  }) async {
    final validated = SourceLocationValidator.validate(kind, location);
    if (!validated.isValid) {
      throw StateError(validated.errorMessage ?? '媒体源地址无效');
    }

    final view = MediaSourceView(
      id: SourceId.trusted(sourceId ?? 'browse_${_nowMs()}'),
      kind: kind,
      label: '目录浏览',
      location: validated.normalizedLocation,
      username:
          kind == MediaSourceKind.local || kind == MediaSourceKind.cloudDrive
          ? null
          : _cleanOptionalText(username),
    );

    String? passwordOverride;
    if (kind != MediaSourceKind.local &&
        kind != MediaSourceKind.cloudDrive &&
        !clearPassword) {
      if (password != null && password.isNotEmpty) {
        passwordOverride = password;
      } else if (sourceId != null && sourceId.isNotEmpty) {
        passwordOverride = await credentialStore.readPassword(sourceId);
      }
    }

    final gateway = await gatewayFactory.create(
      view,
      passwordOverride: passwordOverride,
      clearPassword: clearPassword,
    );
    return SourceDirectoryBrowseSession(gateway);
  }

  /// 软删除媒体源及其关联索引与安全凭据（绝不触碰或删除物理媒体文件）。
  Future<void> deleteSource(String sourceId) async {
    final now = _nowMs();
    final sourceVariants = await _repository.getVariantsBySource(sourceId);
    final affectedWorkIds = <String>{
      for (final variant in sourceVariants) variant.workId,
    };

    for (final variant in sourceVariants) {
      databases.library.mediaVariants.softDelete(
        VariantId.trusted(variant.id),
        deletedAtMs: now,
        sourceDeviceId: sourceDeviceId,
      );
    }

    final ignoredRecords = databases.library.ignoredFolders.listBySource(
      SourceId.trusted(sourceId),
    );
    for (final rec in ignoredRecords) {
      databases.library.ignoredFolders.softDelete(
        rec.id,
        deletedAtMs: now,
        sourceDeviceId: sourceDeviceId,
      );
    }

    databases.library.mediaSources.softDelete(
      SourceId.trusted(sourceId),
      deletedAtMs: now,
      sourceDeviceId: sourceDeviceId,
    );
    SourceScopePrefs.removeSourceMetadata(scopedPrefs, sourceId);
    await credentialStore.deletePassword(sourceId);

    final deletedWorkIds = <String>[];
    for (final workId in affectedWorkIds) {
      final remainingVariants = await _repository.getVariantsByWork(workId);
      final activeEpisodeIds = <String>{
        for (final v in remainingVariants)
          if (v.episodeId != null && v.episodeId!.isNotEmpty) v.episodeId!,
      };
      final workEpisodes = await _repository.getEpisodesByWork(workId);
      for (final ep in workEpisodes) {
        if (!activeEpisodeIds.contains(ep.id)) {
          databases.library.episodes.softDelete(
            EpisodeId.trusted(ep.id),
            deletedAtMs: now,
            sourceDeviceId: sourceDeviceId,
          );
        }
      }

      if (remainingVariants.isEmpty) {
        databases.library.works.softDelete(
          WorkId.trusted(workId),
          deletedAtMs: now,
          sourceDeviceId: sourceDeviceId,
        );
        await _repository.clearScrapeCandidates(workId);
        deletedWorkIds.add(workId);
      }
    }

    eventBus.publish(
      MediaSourceChangedEvent(
        sourceId: SourceId.trusted(sourceId),
        reason: 'deleted',
        occurredAtMs: now,
      ),
    );
    for (final workId in deletedWorkIds) {
      eventBus.publish(
        LibraryWorkChangedEvent(
          workId: WorkId.trusted(workId),
          reason: 'source_deleted',
          occurredAtMs: now,
        ),
      );
    }
    notifyListeners();
  }

  /// 对目录名执行本地自然数段与大小写折叠排序，供目录选择器稳定排列子目录。
  static int compareNaturalFolderName(String a, String b) {
    final na = a.trim().toLowerCase();
    final nb = b.trim().toLowerCase();
    final matchesA = _digitsPattern.allMatches(na).toList(growable: false);
    final matchesB = _digitsPattern.allMatches(nb).toList(growable: false);
    if (matchesA.isEmpty || matchesB.isEmpty) {
      return na.compareTo(nb);
    }
    final segsA = _tokenizeNatural(na);
    final segsB = _tokenizeNatural(nb);
    final len = segsA.length < segsB.length ? segsA.length : segsB.length;
    for (var i = 0; i < len; i++) {
      final pa = segsA[i];
      final pb = segsB[i];
      final numA = int.tryParse(pa);
      final numB = int.tryParse(pb);
      if (numA != null && numB != null) {
        if (numA != numB) return numA.compareTo(numB);
        if (pa.length != pb.length) return pa.length.compareTo(pb.length);
      } else {
        final cmp = pa.compareTo(pb);
        if (cmp != 0) return cmp;
      }
    }
    return segsA.length.compareTo(segsB.length);
  }

  static List<String> _tokenizeNatural(String input) {
    final parts = <String>[];
    var cursor = 0;
    for (final match in _digitsPattern.allMatches(input)) {
      if (match.start > cursor) {
        parts.add(input.substring(cursor, match.start));
      }
      parts.add(match.group(0)!);
      cursor = match.end;
    }
    if (cursor < input.length) {
      parts.add(input.substring(cursor));
    }
    return parts;
  }

  static String? _cleanOptionalText(String? raw) {
    final trimmed = raw?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return trimmed;
  }

  static String _normalizeRelativePath(String raw) {
    return raw
        .trim()
        .replaceAll('\\', '/')
        .replaceAll(_leadingSlashes, '')
        .replaceAll(_trailingSlashes, '');
  }

  static String _normalizeComparableLocation(
    MediaSourceKind kind,
    String location,
  ) {
    final trimmed = location.trim().replaceAll('\\', '/');
    if (kind == MediaSourceKind.local) {
      return trimmed.replaceAll(_trailingSlashes, '').toLowerCase();
    }
    return trimmed.replaceAll(_trailingSlashes, '');
  }
}

/// 单个目录弹窗持有的网关与有界目录缓存，关闭时释放，不跨账号或扫库共享。
final class SourceDirectoryBrowseSession {
  SourceDirectoryBrowseSession(this._gateway);
  final MediaSourceGateway _gateway;
  final _cache = <(String, bool), List<RemoteEntry>>{};
  int _cachedEntries = 0;
  bool _closed = false;
  static const _maxDirectories = 32;
  static const _maxEntries = 12000;

  Future<List<RemoteEntry>> listDirectory(
    String path, {
    bool includeFiles = false,
  }) async {
    if (_closed) throw StateError('目录浏览会话已关闭');
    final key = (path, includeFiles);
    final cached = _cache.remove(key);
    if (cached != null) {
      _cache[key] = cached;
      return cached;
    }
    final entries = await _gateway.listDirectory(path);
    if (_closed) throw StateError('目录浏览会话已关闭');
    final filtered =
        entries
            .where(
              (e) => !e.name.startsWith('.') && (includeFiles || e.isDirectory),
            )
            .toList(growable: false)
          ..sort((a, b) {
            if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
            return SourcesController.compareNaturalFolderName(a.name, b.name);
          });
    final result = List<RemoteEntry>.unmodifiable(filtered);
    if (result.length <= _maxEntries) {
      final previous = _cache.remove(key);
      _cachedEntries -= previous?.length ?? 0;
      _cache[key] = result;
      _cachedEntries += result.length;
      while (_cache.length > _maxDirectories || _cachedEntries > _maxEntries) {
        _cachedEntries -= _cache.remove(_cache.keys.first)!.length;
      }
    }
    return result;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _cache.clear();
    _cachedEntries = 0;
    await _gateway.close();
  }
}
