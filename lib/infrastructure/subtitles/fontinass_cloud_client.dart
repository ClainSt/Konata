import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:developer' as developer;

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../domain/playback/ass_semantic_verifier.dart';
import '../storage/atomic_file_writer.dart';
import '../storage/storage_root_provider.dart';

/// 未授权 Origin 访问云端子集化服务时抛出的安全异常。
class CloudSubsetUnauthorizedException implements Exception {
  /// 创建未授权异常。
  const CloudSubsetUnauthorizedException(this.origin);

  /// 被拦截的未授权 Origin。
  final CloudSubsetOrigin origin;

  @override
  String toString() => 'CloudSubsetUnauthorizedException: 未授权访问云端子集化源 $origin';
}

/// 云端子集化响应触发跨源或任意 HTTP 重定向时抛出的拦截异常。
class CloudSubsetRedirectBlockedException implements Exception {
  /// 创建重定向拦截异常。
  const CloudSubsetRedirectBlockedException({
    required this.statusCode,
    this.location,
  });

  /// 被拦截的 HTTP 3xx 状态码。
  final int statusCode;

  /// 响应头中的跳转目标地址。
  final String? location;

  @override
  String toString() =>
      'CloudSubsetRedirectBlockedException: 严禁跟随云端子集化重定向 ($statusCode -> $location)';
}

/// 云端子集化响应未通过逐事件语义同构或字形魔数校验时抛出的安全异常。
class CloudSubsetSemanticRejectedException implements Exception {
  /// 创建语义校验拒绝异常。
  const CloudSubsetSemanticRejectedException(this.reason);

  /// 语义或字形检验失败原因。
  final String reason;

  @override
  String toString() => 'CloudSubsetSemanticRejectedException: $reason';
}

/// 云端子集化请求因撤权或按域取消而中止时抛出的异常。
class CloudSubsetCancelledException implements Exception {
  /// 创建取消异常。
  const CloudSubsetCancelledException([this.reason = '云端子集化任务已撤权或取消']);

  /// 取消原因描述。
  final String reason;

  @override
  String toString() => 'CloudSubsetCancelledException: $reason';
}

/// 逐 Origin（`scheme + host + port`）云端子集化授权管理器（支持本地持久化落盘防重启丢失）。
class CloudSubsetAuthorizationStore {
  /// 创建逐 Origin 授权仓储；可选注入异步持久化读写回调与变更通知。
  CloudSubsetAuthorizationStore({
    this.onLoad,
    this.onPersist,
    this.onHydrated,
  }) {
    if (onLoad != null) {
      _hydrationFuture = _hydrateFromStorage();
    }
  }

  /// 从持久化存储加载已授权 Origin 列表的回调。
  final Future<List<String>> Function()? onLoad;

  /// 将最新已授权 Origin 列表落盘的回调。
  final Future<void> Function(List<String> originKeys)? onPersist;

  /// 持久化白名单恢复完成后的通知回调。
  final void Function()? onHydrated;
  final Set<CloudSubsetOrigin> _authorizedOrigins = {};
  final Set<CloudSubsetOrigin> _revokedBeforeHydration = {};
  Future<void>? _hydrationFuture;
  Future<void> _persistChain = Future<void>.value();

  /// 当前已授权的规范化 Origin 键只读列表（按字典序排列）。
  List<String> get authorizedOriginKeys {
    final keys = _authorizedOrigins.map((o) => o.key).toList()..sort();
    return List<String>.unmodifiable(keys);
  }

  /// 等待初始本地持久化白名单恢复完成（未配置持久化时立即返回）。
  Future<void> ensureHydrated() async {
    await (_hydrationFuture ?? Future<void>.value());
  }

  /// 等待最近一次授权变更落盘完成（便于测试验证重启持久性）。
  Future<void> flushPendingPersistence() => _persistChain;

  Future<void> _hydrateFromStorage() async {
    final loader = onLoad;
    if (loader == null) return;
    try {
      final stored = await loader();
      var addedAny = false;
      for (final raw in stored) {
        final uri = Uri.tryParse(raw.trim());
        if (uri == null || !uri.hasScheme || uri.host.isEmpty) continue;
        final origin = CloudSubsetOrigin.fromUri(uri);
        if (_revokedBeforeHydration.contains(origin)) continue;
        if (_authorizedOrigins.add(origin)) {
          addedAny = true;
        }
      }
      if (addedAny) {
        onHydrated?.call();
      }
    } on Object catch (error) {
  // 无插件或存储受限环境下保持空授权集合，严禁默认放行未授权源。
  developer.log('可恢复异常已记录', name: 'konata.fontinass_cloud_client', error: error);
}
  }

  void _schedulePersist() {
    final persister = onPersist;
    if (persister == null) return;
    final snapshot = authorizedOriginKeys;
    _persistChain = _persistChain.then((_) async {
      try {
        await persister(snapshot);
      } on Object catch (error) {
  // 持久化失败不影响内存态本次撤权/授权立即生效。
  developer.log('可恢复异常已记录', name: 'konata.fontinass_cloud_client', error: error);
}
    });
  }

  /// 显式授权指定服务地址对应的 `(scheme, host, port)` Origin 并异步落盘。
  CloudSubsetOrigin grant(Uri endpointUri) {
    final origin = CloudSubsetOrigin.fromUri(endpointUri);
    _revokedBeforeHydration.remove(origin);
    _authorizedOrigins.add(origin);
    _schedulePersist();
    return origin;
  }

  /// 撤销指定服务地址对应 Origin 的授权并异步落盘。
  void revoke(Uri endpointUri) {
    final origin = CloudSubsetOrigin.fromUri(endpointUri);
    _revokedBeforeHydration.add(origin);
    _authorizedOrigins.remove(origin);
    _schedulePersist();
  }

  /// 清空全部云端授权记录并异步落盘。
  void clear() {
    _revokedBeforeHydration.addAll(_authorizedOrigins);
    _authorizedOrigins.clear();
    _schedulePersist();
  }

  /// 判断目标请求地址的 `(scheme, host, port)` Origin 是否已获得显式授权。
  bool isAuthorized(Uri endpointUri) {
    final origin = CloudSubsetOrigin.fromUri(endpointUri);
    return _authorizedOrigins.contains(origin);
  }
}

/// 云端子集化单次请求的可取消令牌（与上游按域令牌桥接，支持中途立即关闭底层连接）。
class CloudSubsetCancellationHandle {
  bool _cancelled = false;
  final List<void Function()> _listeners = [];

  /// 是否已触发取消。
  bool get isCancelled => _cancelled;

  /// 注册底层连接中止回调；若当前已取消则立即同步执行。
  void addCancelListener(void Function() listener) {
    if (_cancelled) {
      listener();
      return;
    }
    _listeners.add(listener);
  }

  /// 触发取消并即时通知所有在途连接中止。
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final snapshot = List<void Function()>.from(_listeners);
    _listeners.clear();
    for (final fn in snapshot) {
      try {
        fn();
      } catch (error) {
      developer.log('可恢复异常已记录', name: 'konata.fontinass_cloud_client', error: error);
    }
    }
  }
}

/// 云端子集化原子落盘结果。
class CloudSubsetResult {
  /// 创建云端子集化结果。
  const CloudSubsetResult({
    required this.subsettedAssContent,
    required this.cachedFilePath,
    required this.origin,
    required this.sourceSha1,
    required this.verification,
    this.fromLocalCache = false,
  });

  /// 通过逐事件语义校验的子集化 ASS 正文。
  final String subsettedAssContent;

  /// 原子落盘后的本地缓存文件路径。
  final String cachedFilePath;

  /// 实际执行子集化的已授权 Origin。
  final CloudSubsetOrigin origin;

  /// 原始字幕内容 SHA-1 摘要。
  final String sourceSha1;

  /// 语义同构与字体魔数校验报告。
  final AssSemanticVerificationResult verification;

  /// 本次是否直接命中本地已验证缓存。
  final bool fromLocalCache;
}

/// FontInAss 可选云端字幕字体子集化纯净客户端。
///
/// 严格执行四项安全红线：
/// 1. 授权绑定 `(scheme, host, port)` Origin，未授权源直接拒绝；
/// 2. 强制 `followRedirects = false`，遇任何 `301/302/303/307/308` 立即拦截，严禁跨源转发字幕正文；
/// 3. 省略 `X-Filename` 保护隐私，附带 `X-Font-Name-Mode: alias` 与 `X-Fonts-Check: 0`；
/// 4. 响应正文必须先通过 `AssSemanticVerifier` 逐事件语义与零退化检验，再经 `.part -> rename` 原子入库。
class FontInAssCloudClient {
  /// 创建 FontInAss 云端子集化客户端。
  FontInAssCloudClient({
    required this.authorizationStore,
    StorageRootService? storageRoot,
    this.requestTimeout = const Duration(seconds: 20),
    this.maxResponseBytes = 48 * 1024 * 1024,
  }) : _storageRoot = storageRoot ?? const StorageRootService();

  /// 逐 Origin 授权仓库。
  final CloudSubsetAuthorizationStore authorizationStore;

  final StorageRootService _storageRoot;

  /// 单次请求超时上限。
  final Duration requestTimeout;

  /// 云端返回子集化字幕体积上限（48 MiB，含内嵌 UUE 字体）。
  final int maxResponseBytes;

  /// 执行一次受 Origin 授权、禁重定向与逐事件语义校验保护的云端子集化请求。
  Future<CloudSubsetResult> requestSubset({
    required Uri endpointUri,
    required String originalAssContent,
    CloudSubsetCancellationHandle? cancellation,
    bool Function()? isTaskAlive,
  }) async {
    final origin = CloudSubsetOrigin.fromUri(endpointUri);
    if (!authorizationStore.isAuthorized(endpointUri)) {
      throw CloudSubsetUnauthorizedException(origin);
    }
    _throwIfAborted(cancellation, isTaskAlive, endpointUri);

    final srcBytes = utf8.encode(originalAssContent);
    final srcSha1 = sha1.convert(srcBytes).toString();
    final cacheDir = await _storageRoot.ensureCloudSubtitleCacheDir();
    final originHash = sha1.convert(utf8.encode(origin.key)).toString().substring(0, 12);
    final cacheFile = File(p.join(cacheDir.path, '${originHash}_$srcSha1.ass'));

    // 命中此前已通过语义校验并原子落盘的本地缓存时直接复用。
    if (await cacheFile.exists() && await cacheFile.length() > 0) {
      final cachedText = await cacheFile.readAsString();
      final cachedVerify = AssSemanticVerifier.verify(
        originalAss: originalAssContent,
        subsettedAss: cachedText,
      );
      if (cachedVerify.isValid) {
        return CloudSubsetResult(
          subsettedAssContent: cachedText,
          cachedFilePath: cacheFile.path,
          origin: origin,
          sourceSha1: srcSha1,
          verification: cachedVerify,
          fromLocalCache: true,
        );
      }
    }

    final httpClient = HttpClient()..connectionTimeout = requestTimeout;
    var abortedBySignal = false;
    void abortHttp() {
      abortedBySignal = true;
      httpClient.close(force: true);
    }

    cancellation?.addCancelListener(abortHttp);

    try {
      _throwIfAborted(cancellation, isTaskAlive, endpointUri);
      final req = await httpClient.postUrl(endpointUri).timeout(requestTimeout);
      // 严禁任何自动跟随重定向，防止用户字幕正文被 307/308 转发至未授权第三方源。
      req.followRedirects = false;
      req.maxRedirects = 0;
      req.headers.contentType = ContentType('text', 'plain', charset: 'utf-8');
      req.headers.set('X-Font-Name-Mode', 'alias');
      req.headers.set('X-Fonts-Check', '0');
      // 显式省略 X-Filename，避免泄露用户本地文件名隐私。
      req.headers.removeAll('X-Filename');
      req.contentLength = srcBytes.length;
      req.add(srcBytes);

      final resp = await req.close().timeout(requestTimeout);
      _throwIfAborted(cancellation, isTaskAlive, endpointUri);

      final status = resp.statusCode;
      if (status == HttpStatus.movedPermanently ||
          status == HttpStatus.found ||
          status == HttpStatus.seeOther ||
          status == HttpStatus.temporaryRedirect ||
          status == HttpStatus.permanentRedirect ||
          (status >= 300 && status < 400)) {
        await resp.drain<void>().catchError((_) {});
        throw CloudSubsetRedirectBlockedException(
          statusCode: status,
          location: resp.headers.value(HttpHeaders.locationHeader),
        );
      }

      if (status < 200 || status >= 300) {
        await resp.drain<void>().catchError((_) {});
        throw HttpException('云端子集化服务返回异常状态码: HTTP $status', uri: endpointUri);
      }

      final builder = BytesBuilder(copy: false);
      await for (final chunk in resp.timeout(requestTimeout)) {
        _throwIfAborted(cancellation, isTaskAlive, endpointUri);
        builder.add(chunk);
        if (builder.length > maxResponseBytes) {
          throw const FormatException('云端子集化响应体积超出安全上限');
        }
      }

      _throwIfAborted(cancellation, isTaskAlive, endpointUri);
      final subsettedAss = utf8.decode(builder.takeBytes(), allowMalformed: false);

      // 落盘前强制逐事件时间/图层/文本/标签语义同构 + 零字形退化核验。
      final verification = AssSemanticVerifier.verify(
        originalAss: originalAssContent,
        subsettedAss: subsettedAss,
      );
      if (!verification.isValid) {
        throw CloudSubsetSemanticRejectedException(
          verification.failureReason ?? '未知语义失配',
        );
      }

      // 同卷 .part 临时文件校验后原子 rename 入库，严禁留下损坏缓存。
      final partFile = File(
        '${cacheFile.path}.part.${DateTime.now().microsecondsSinceEpoch}',
      );
      try {
        await partFile.writeAsBytes(utf8.encode(subsettedAss), flush: true);
        _throwIfAborted(cancellation, isTaskAlive, endpointUri);
        await AtomicFileWriter.replaceFile(partFile, cacheFile);
      } finally {
        if (await partFile.exists()) {
          await partFile.delete().catchError((_) => partFile);
        }
      }

      return CloudSubsetResult(
        subsettedAssContent: subsettedAss,
        cachedFilePath: cacheFile.path,
        origin: origin,
        sourceSha1: srcSha1,
        verification: verification,
        fromLocalCache: false,
      );
    } on CloudSubsetCancelledException {
      rethrow;
    } on CloudSubsetRedirectBlockedException {
      rethrow;
    } on CloudSubsetSemanticRejectedException {
      rethrow;
    } on CloudSubsetUnauthorizedException {
      rethrow;
    } catch (e) {
      if (abortedBySignal ||
          (cancellation?.isCancelled ?? false) ||
          (isTaskAlive != null && !isTaskAlive()) ||
          !authorizationStore.isAuthorized(endpointUri)) {
        throw const CloudSubsetCancelledException();
      }
      rethrow;
    } finally {
      httpClient.close(force: true);
    }
  }

  void _throwIfAborted(
    CloudSubsetCancellationHandle? cancellation,
    bool Function()? isTaskAlive,
    Uri endpointUri,
  ) {
    if (cancellation?.isCancelled ?? false) {
      throw const CloudSubsetCancelledException('云端子集化任务已主动取消');
    }
    if (isTaskAlive != null && !isTaskAlive()) {
      throw const CloudSubsetCancelledException('云端子集化分域任务令牌已失效');
    }
    if (!authorizationStore.isAuthorized(endpointUri)) {
      throw const CloudSubsetCancelledException('目标 Origin 授权已在中途撤销');
    }
  }
}
