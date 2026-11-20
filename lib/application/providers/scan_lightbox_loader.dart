import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../domain/models/media_source.dart';
import '../../domain/models/media_variant.dart';
import '../../domain/models/network_config.dart';
import '../../domain/repositories/file_system_gateway.dart';
import '../../infrastructure/logging/diagnostics_log_store.dart';
import '../../infrastructure/sources/byte_stream_source_gateway.dart';
import '../../infrastructure/sources/source_gateway_factory.dart';
import 'diagnostics_providers.dart';
import 'playback_providers.dart';

/// 单次高清扫图内存流式拉取句柄（支持即时中止并安全释放上游连接）。
class ScanImageLoadHandle {
  /// 创建流式加载句柄。
  ScanImageLoadHandle({
    required this.future,
    required this._onCancel,
  });

  /// 解析完成后的原始图像字节流；若已被取消则返回 `null`。
  final Future<Uint8List?> future;

  final Future<void> Function() _onCancel;

  /// 立即中止在途字节流并关闭底层网关连接。
  Future<void> cancel() => _onCancel();
}

/// Scan 画集高清大图只读流式加载服务（隔离 `dart:io` 与媒体源网关细节，原图严禁落盘）。
class ScanLightboxLoaderService {
  /// 创建扫图流式加载服务。
  const ScanLightboxLoaderService({
    required this.gatewayFactory,
    required this.logStore,
  });

  final MediaSourceGatewayFactory gatewayFactory;
  final DiagnosticsLogStore logStore;

  /// 按上限流式读取单张扫图原图字节至内存；若媒体源不支持字节流则抛出 [StateError]。
  ScanImageLoadHandle startLoad({
    required MediaVariant variant,
    required MediaSource source,
  }) {
    var cancelled = false;
    StreamSubscription<List<int>>? activeSub;
    MediaSourceGateway? activeGateway;

    Future<void> cleanup() async {
      cancelled = true;
      final sub = activeSub;
      activeSub = null;
      if (sub != null) {
        try {
          await sub.cancel();
        } catch (e) {
          logStore.record('SCAN', '取消扫图流订阅失败：$e', isError: true);
        }
      }
      final gw = activeGateway;
      activeGateway = null;
      if (gw != null) {
        try {
          await gw.close();
        } catch (e) {
          logStore.record('SCAN', '关闭扫图媒体源网关失败：$e', isError: true);
        }
      }
    }

    Future<Uint8List?> run() async {
      final gw = await gatewayFactory.create(source);
      if (cancelled) {
        await gw.close();
        return null;
      }
      activeGateway = gw;

      if (gw is! ByteRangeReadableGateway) {
        await cleanup();
        throw StateError('当前媒体源不支持流式读取高清大图');
      }

      final byteGw = gw as ByteRangeReadableGateway;
      // 取消冗余 probeFileLength 探测，直接发起单次流式读取：
      // - WebDAV / 本地传入 endInclusive: null，兼容 206 与 200 并复用 Keep-Alive 连接池；
      // - SMB 在已知 fileSize 时传入精确右边界以省去网关内部二次 stat 往返。
      final int? endInclusive =
          (source.kind == MediaSourceKind.smb && variant.fileSize > 0)
          ? math.min(variant.fileSize, TmdbNetworkConfig.maxScanFullImageBytes) -
                1
          : null;

      final stream = await byteGw.openByteRange(
        variant.relativePath,
        start: 0,
        endInclusive: endInclusive,
      );
      if (cancelled) {
        await cleanup();
        return null;
      }

      final builder = BytesBuilder(copy: false);
      final done = Completer<Uint8List?>();
      late final StreamSubscription<List<int>> sub;
      sub = stream.listen(
        (chunk) {
          if (cancelled) {
            unawaited(sub.cancel());
            if (!done.isCompleted) done.complete(null);
            return;
          }
          builder.add(chunk);
          if (builder.length >= TmdbNetworkConfig.maxScanFullImageBytes) {
            unawaited(sub.cancel());
            if (!done.isCompleted) done.complete(builder.takeBytes());
          }
        },
        onError: (Object err) {
          if (!done.isCompleted) done.completeError(err);
        },
        onDone: () {
          if (!done.isCompleted) {
            done.complete(builder.takeBytes());
          }
        },
        cancelOnError: true,
      );
      activeSub = sub;

      try {
        final bytes = await done.future;
        return cancelled ? null : bytes;
      } finally {
        await cleanup();
      }
    }

    return ScanImageLoadHandle(future: run(), onCancel: cleanup);
  }

  /// 异步校验本地原图是否存在并返回规范绝对路径（供桌面端外部看图拉起）。
  Future<String?> resolveExistingLocalPath({
    required MediaVariant variant,
    required MediaSource source,
  }) async {
    if (source.kind != MediaSourceKind.local) return null;
    final relSegments = variant.relativePath
        .split(RegExp(r'[/\\]+'))
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    final fullPath = p.normalize(p.joinAll([source.location, ...relSegments]));
    final file = File(fullPath);
    if (!await file.exists()) return null;
    return file.path;
  }
}

/// Scan 画集大图流式加载服务 Provider。
final scanLightboxLoaderProvider = Provider<ScanLightboxLoaderService>((ref) {
  return ScanLightboxLoaderService(
    gatewayFactory: ref.read(mediaSourceGatewayFactoryProvider),
    logStore: ref.read(diagnosticsLogStoreProvider),
  );
});
