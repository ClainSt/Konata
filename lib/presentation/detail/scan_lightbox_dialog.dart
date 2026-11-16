import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../../application/providers/library_providers.dart';
import '../../domain/models/media_source.dart';
import '../../domain/models/media_variant.dart';
import '../../domain/models/network_config.dart';
import '../../domain/repositories/file_system_gateway.dart';
import '../../infrastructure/sources/byte_stream_source_gateway.dart';
import '../../infrastructure/sources/source_gateway_factory.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/konata_toast.dart';

/// Scan 画集毛玻璃全屏高清预览浮层：
/// - 每次仅在内存中流式加载当前单张原图，严禁批量预拉与 `%TEMP%` 落盘；
/// - 切换上/下一张或关闭弹窗时，立即中断在途流并调用 `MemoryImage.evict()` 释放高清位图内存；
/// - 支持鼠标滚轮以指针为锚点缩放（`1.0x–5.0x`）、拖拽平移、双击还原，以及 `← / → / Esc` 快捷键。
class ScanLightboxDialog extends StatefulWidget {
  /// 创建 Scan 画集高清大图浏览弹窗。
  const ScanLightboxDialog({
    super.key,
    required this.bundle,
    required this.initialVariant,
  });

  /// 当前作品详情数据包。
  final WorkDetailBundle bundle;

  /// 初始定位的扫图条目。
  final MediaVariant initialVariant;

  @override
  State<ScanLightboxDialog> createState() => _ScanLightboxDialogState();
}

class _ScanLightboxDialogState extends State<ScanLightboxDialog> {
  static const double _minScale = 1.0;
  static const double _maxScale = 5.0;

  final TransformationController _transformController =
      TransformationController();

  late int _index;
  int _loadEpoch = 0;
  bool _loading = false;
  String? _errorText;
  MemoryImage? _activeImageProvider;
  double _currentScale = 1.0;

  StreamSubscription<List<int>>? _activeStreamSub;
  MediaSourceGateway? _activeGateway;

  @override
  void initState() {
    super.initState();
    _transformController.addListener(_handleTransformChanged);
    final scans = widget.bundle.scanVariants;
    final found = scans.indexWhere((s) => s.id == widget.initialVariant.id);
    _index = found >= 0 ? found : 0;
    if (scans.isNotEmpty) {
      unawaited(_loadCurrentScan());
    }
  }

  @override
  void dispose() {
    _transformController.removeListener(_handleTransformChanged);
    _transformController.dispose();
    unawaited(_abortInFlightAndEvict());
    super.dispose();
  }

  void _handleTransformChanged() {
    final scale = _transformController.value.storage[0].clamp(
      _minScale,
      _maxScale,
    );
    if ((scale - _currentScale).abs() > 0.005 && mounted) {
      setState(() => _currentScale = scale);
    }
  }

  Future<void> _abortInFlightAndEvict() async {
    final sub = _activeStreamSub;
    _activeStreamSub = null;
    if (sub != null) {
      try {
        await sub.cancel();
      } catch (_) {}
    }
    final gw = _activeGateway;
    _activeGateway = null;
    if (gw != null) {
      try {
        await gw.close();
      } catch (_) {}
    }
    final prev = _activeImageProvider;
    _activeImageProvider = null;
    if (prev != null) {
      try {
        await prev.evict();
      } catch (_) {}
    }
  }

  Future<void> _selectIndex(int nextIndex) async {
    final scans = widget.bundle.scanVariants;
    if (nextIndex < 0 || nextIndex >= scans.length || nextIndex == _index) {
      return;
    }
    setState(() {
      _index = nextIndex;
      _errorText = null;
    });
    _resetZoom();
    await _loadCurrentScan();
  }

  Future<void> _loadCurrentScan() async {
    final scans = widget.bundle.scanVariants;
    if (scans.isEmpty) return;

    final epoch = ++_loadEpoch;
    await _abortInFlightAndEvict();
    if (!mounted || epoch != _loadEpoch) return;

    final current = scans[_index.clamp(0, scans.length - 1)];
    final source = widget.bundle.sourcesById[current.sourceId];
    if (source == null) {
      setState(() {
        _loading = false;
        _errorText = '找不到当前画集所属媒体源配置';
      });
      return;
    }

    setState(() {
      _loading = true;
      _errorText = null;
    });

    try {
      final gw = await const MediaSourceGatewayFactory().create(source);
      if (!mounted || epoch != _loadEpoch) {
        await gw.close();
        return;
      }
      _activeGateway = gw;

      if (gw is! ByteRangeReadableGateway) {
        await gw.close();
        _activeGateway = null;
        if (mounted && epoch == _loadEpoch) {
          setState(() {
            _loading = false;
            _errorText = '当前媒体源不支持流式读取高清大图';
          });
        }
        return;
      }

      final byteGw = gw as ByteRangeReadableGateway;
      final fileLen = await byteGw.probeFileLength(current.relativePath);
      if (!mounted || epoch != _loadEpoch) {
        await _abortInFlightAndEvict();
        return;
      }

      final endInclusive = (fileLen != null && fileLen > 0)
          ? (fileLen > TmdbNetworkConfig.maxScanFullImageBytes
                ? TmdbNetworkConfig.maxScanFullImageBytes - 1
                : fileLen - 1)
          : TmdbNetworkConfig.maxScanFullImageBytes - 1;
      if (endInclusive < 0) {
        await _abortInFlightAndEvict();
        if (mounted && epoch == _loadEpoch) {
          setState(() {
            _loading = false;
            _errorText = '当前图像文件为空';
          });
        }
        return;
      }

      final stream = await byteGw.openByteRange(
        current.relativePath,
        start: 0,
        endInclusive: endInclusive,
      );
      if (!mounted || epoch != _loadEpoch) {
        await _abortInFlightAndEvict();
        return;
      }

      final builder = BytesBuilder(copy: false);
      final done = Completer<Uint8List?>();
      late final StreamSubscription<List<int>> sub;
      sub = stream.listen(
        (chunk) {
          if (!mounted || epoch != _loadEpoch) {
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
      _activeStreamSub = sub;

      final bytes = await done.future;
      if (identical(_activeStreamSub, sub)) {
        _activeStreamSub = null;
      }
      if (identical(_activeGateway, gw)) {
        _activeGateway = null;
      }
      await gw.close();

      if (!mounted || epoch != _loadEpoch) return;

      if (bytes == null || bytes.isEmpty) {
        setState(() {
          _loading = false;
          _errorText = '无法读取当前画集图像内容';
        });
        return;
      }

      final provider = MemoryImage(bytes);
      setState(() {
        _activeImageProvider = provider;
        _loading = false;
        _errorText = null;
      });
    } catch (err) {
      if (!mounted || epoch != _loadEpoch) return;
      await _abortInFlightAndEvict();
      if (!mounted || epoch != _loadEpoch) return;
      setState(() {
        _loading = false;
        _errorText = '加载高清画集失败: $err';
      });
    }
  }

  void _resetZoom() {
    _transformController.value = Matrix4.identity();
    if (mounted && _currentScale != 1.0) {
      setState(() => _currentScale = 1.0);
    }
  }

  void _handleWheelZoom(
    PointerSignalEvent event,
    double viewportWidth,
    double viewportHeight,
  ) {
    if (event is! PointerScrollEvent || _activeImageProvider == null) return;
    if (event.scrollDelta.dy == 0) return;

    final matrix = _transformController.value;
    final currentScale = matrix.storage[0] <= 0 ? 1.0 : matrix.storage[0];
    final currentTx = matrix.storage[12];
    final currentTy = matrix.storage[13];

    final factor = event.scrollDelta.dy < 0 ? 1.18 : 1 / 1.18;
    final nextScale = (currentScale * factor).clamp(_minScale, _maxScale);
    if ((nextScale - currentScale).abs() < 0.001) return;

    if (nextScale <= 1.002) {
      _resetZoom();
      return;
    }

    final ratio = nextScale / currentScale;
    final focal = event.localPosition;
    final rawTx = focal.dx - ratio * (focal.dx - currentTx);
    final rawTy = focal.dy - ratio * (focal.dy - currentTy);

    final minTx = viewportWidth * (1.0 - nextScale);
    final minTy = viewportHeight * (1.0 - nextScale);
    final clampedTx = rawTx.clamp(minTx <= 0 ? minTx : 0.0, 0.0);
    final clampedTy = rawTy.clamp(minTy <= 0 ? minTy : 0.0, 0.0);

    _transformController.value = Matrix4(
      nextScale,
      0,
      0,
      0,
      0,
      nextScale,
      0,
      0,
      0,
      0,
      1,
      0,
      clampedTx,
      clampedTy,
      0,
      1,
    );
  }

  Future<void> _openInSystemViewer(
    MediaVariant current,
    MediaSource? source,
  ) async {
    if (source == null || source.kind != MediaSourceKind.local) {
      if (!mounted) return;
      showKonataToast(
        context,
        '远程媒体源不在本地写临时文件，请直接在当前浮层滚轮缩放查看原图',
      );
      return;
    }

    final relSegments = current.relativePath
        .split(RegExp(r'[/\\]+'))
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    final fullPath = p.normalize(p.joinAll([source.location, ...relSegments]));
    final file = File(fullPath);
    if (!await file.exists()) {
      if (!mounted) return;
      showKonataToast(context, '本地原图文件不存在或不可访问');
      return;
    }

    final ok = await launchUrl(
      Uri.file(file.path),
      mode: LaunchMode.externalApplication,
    );
    if (!ok && mounted) {
      showKonataToast(context, '无法拉起系统图片查看器');
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final scans = widget.bundle.scanVariants;
    if (scans.isEmpty) {
      return const SizedBox.shrink();
    }
    final safeIdx = _index.clamp(0, scans.length - 1);
    final current = scans[safeIdx];
    final source = widget.bundle.sourcesById[current.sourceId];
    final size = MediaQuery.sizeOf(context);
    final dialogWidth = (size.width * 0.88).clamp(640.0, 1320.0);
    final dialogHeight = (size.height * 0.86).clamp(480.0, 880.0);

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).pop(),
        if (scans.length > 1)
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () {
            if (safeIdx > 0) unawaited(_selectIndex(safeIdx - 1));
          },
        if (scans.length > 1)
          const SingleActivator(LogicalKeyboardKey.arrowRight): () {
            if (safeIdx < scans.length - 1) unawaited(_selectIndex(safeIdx + 1));
          },
      },
      child: Focus(
        autofocus: true,
        child: Dialog(
          backgroundColor: Colors.transparent,
          elevation: 0,
          insetPadding: const EdgeInsets.all(24),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
              child: Container(
                width: dialogWidth,
                height: dialogHeight,
                decoration: BoxDecoration(
                  color: KonataTheme.lightboxDarkSurface.withValues(alpha: 0.82),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.16),
                  ),
                ),
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 12, 12, 10),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  current.fileName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: KonataTheme.detailTextStyle(
                                    color: Colors.white,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  '${safeIdx + 1} / ${scans.length} · ${current.relativePath}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: KonataTheme.detailTextStyle(
                                    color: Colors.white.withValues(alpha: 0.65),
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w400,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.12),
                              ),
                            ),
                            child: Text(
                              '${(_currentScale * 100).round()}%',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: '重置缩放（双击画面也可还原）',
                            onPressed: _currentScale > 1.005
                                ? _resetZoom
                                : null,
                            icon: const Icon(
                              Icons.fit_screen_rounded,
                              color: Colors.white,
                              size: 19,
                            ),
                          ),
                          IconButton(
                            tooltip: '用系统图片查看器打开',
                            onPressed: () =>
                                unawaited(_openInSystemViewer(current, source)),
                            icon: const Icon(
                              Icons.open_in_new_rounded,
                              color: Colors.white,
                              size: 19,
                            ),
                          ),
                          if (scans.length > 1) ...[
                            IconButton(
                              tooltip: '上一张 (←)',
                              onPressed: safeIdx > 0
                                  ? () => unawaited(_selectIndex(safeIdx - 1))
                                  : null,
                              icon: const Icon(
                                Icons.chevron_left_rounded,
                                color: Colors.white,
                              ),
                            ),
                            IconButton(
                              tooltip: '下一张 (→)',
                              onPressed: safeIdx < scans.length - 1
                                  ? () => unawaited(_selectIndex(safeIdx + 1))
                                  : null,
                              icon: const Icon(
                                Icons.chevron_right_rounded,
                                color: Colors.white,
                              ),
                            ),
                          ],
                          IconButton(
                            tooltip: '关闭 (Esc)',
                            onPressed: () => Navigator.of(context).pop(),
                            icon: const Icon(
                              Icons.close_rounded,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Divider(height: 1, color: p.hairline),
                    Expanded(
                      child: _buildViewportBody(p),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildViewportBody(KonataPalette p) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_errorText != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _errorText!,
            textAlign: TextAlign.center,
            style: TextStyle(color: p.danger, fontSize: 13.5),
          ),
        ),
      );
    }
    final provider = _activeImageProvider;
    if (provider == null) {
      return Center(
        child: Text(
          '无法读取当前画集图像内容',
          style: TextStyle(color: Colors.white.withValues(alpha: 0.72)),
        ),
      );
    }

    return LayoutBuilder(
      builder: (_, constraints) {
        final vw = constraints.maxWidth;
        final vh = constraints.maxHeight;
        return Listener(
          onPointerSignal: (event) => _handleWheelZoom(event, vw, vh),
          child: GestureDetector(
            onDoubleTap: _resetZoom,
            child: InteractiveViewer(
              transformationController: _transformController,
              panEnabled: true,
              scaleEnabled: true,
              minScale: _minScale,
              maxScale: _maxScale,
              clipBehavior: Clip.hardEdge,
              child: SizedBox(
                width: vw,
                height: vh,
                child: Center(
                  child: Image(
                    image: provider,
                    fit: BoxFit.contain,
                    gaplessPlayback: false,
                    errorBuilder: (_, _, _) => Text(
                      '图像解码失败或格式不受支持',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.72),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
