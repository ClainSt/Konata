import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../playback/unified_playback_engine.dart';
import 'artwork_provider.dart';
import 'scraping_providers.dart';

/// 平台原生层内存与图形设备回吐回调签名（Windows 组装根绑定 D3D11/DXGI 与工作集收缩，Android 保持空操作）。
typedef NativeMemoryTrimmer =
    Future<void> Function({bool releaseIdleDevice, bool trimWorkingSet});

/// UI 解码位图缓存（Flutter `ImageCache`）收缩回调签名（由应用启动入口注入，避免应用层直引渲染包）。
typedef UiImageCacheTrimmer = void Function();

/// 平台原生内存收缩器 Provider（Android 默认空实现，Windows 由组装根注入）。
final konataNativeMemoryTrimmerProvider = Provider<NativeMemoryTrimmer>(
  (ref) =>
      ({bool releaseIdleDevice = false, bool trimWorkingSet = false}) async {},
);

/// UI 图片位图缓存收缩器 Provider（由双端组装根注入 `PaintingBinding.instance.imageCache.clear`）。
final konataUiImageCacheTrimmerProvider = Provider<UiImageCacheTrimmer>(
  (ref) => () {},
);

/// 全站统一内存与图形资源回吐协调器（Riverpod 托管，零全局可变静态状态）。
///
/// 职责边界：
/// 1. 进入全屏视频时清理非活跃后台页面的解码位图与压缩字节缓存，把可用内存让给解码器；
/// 2. 视频/音频会话完整退出并静默满 6 秒后，自动释放闲置 D3D11 复用设备、瞬态封面缓存并回吐 OS 空闲工作集；
/// 3. 应用切入最小化或后台隐藏态时立即收缩非活跃图片缓存与空闲工作集，消除静息高驻留。
class KonataMemoryCoordinator {
  /// 创建内存与资源回吐协调器。
  KonataMemoryCoordinator(this._ref);

  /// 桌面端 Flutter `ImageCache` 推荐解码位图上限（36 MiB）。
  static const int desktopImageCacheMaxBytes = 36 * 1024 * 1024;

  /// 桌面端 Flutter `ImageCache` 推荐条目上限。
  static const int desktopImageCacheMaxEntries = 120;

  /// 移动端 Flutter `ImageCache` 推荐解码位图上限（48 MiB）。
  static const int androidImageCacheMaxBytes = 48 * 1024 * 1024;

  /// 移动端 Flutter `ImageCache` 推荐条目上限。
  static const int androidImageCacheMaxEntries = 120;

  /// 播放结束后触发闲置回收的延迟时长。
  static const Duration postPlaybackIdleDelay = Duration(seconds: 6);

  final Ref _ref;
  Timer? _postPlaybackTimer;
  bool _disposed = false;

  /// 取消尚未触发的停播后闲置回收定时器（在开启新播放会话时立即调用）。
  void cancelPostPlaybackTrim() {
    _postPlaybackTimer?.cancel();
    _postPlaybackTimer = null;
  }

  /// 进入全屏视频播放前清理非活跃后台页位图与压缩字节缓存，不干扰正在显示的活体图像。
  void onEnterFullscreenVideo() {
    if (_disposed) return;
    cancelPostPlaybackTrim();
    _trimManagedImageCaches(includeAudioCovers: false);
  }

  /// 退出作品详情页后立即驱逐已失活的 1920px 背景大图与压缩字节缓存，避免静息常驻堆高企。
  ///
  /// 仅清理无活跃监听的非活体缓存条目，媒体库正在展示的海报位图仍受 `liveImages` 保护不会闪烁。
  void onExitWorkDetail() {
    if (_disposed) return;
    _trimManagedImageCaches(includeAudioCovers: false);
  }

  /// 播放会话完整结束时预约闲置回吐（若期间重新起播则自动取消）。
  void schedulePostPlaybackTrim({Duration delay = postPlaybackIdleDelay}) {
    if (_disposed) return;
    _postPlaybackTimer?.cancel();
    _postPlaybackTimer = Timer(delay, () {
      _postPlaybackTimer = null;
      if (_disposed) return;
      final engine = _ref.read(unifiedPlaybackEngineProvider);
      if (engine.activeStage != PlaybackStageKind.none ||
          engine.liveNativeClientCount > 0) {
        return;
      }
      unawaited(
        trimIdleMemory(releaseIdleDevice: true, trimWorkingSet: true),
      );
    });
  }

  /// 应用最小化或切入后台隐藏时主动收缩图片缓存与空闲工作集。
  Future<void> onAppHiddenOrMinimized() async {
    if (_disposed) return;
    final engine = _ref.read(unifiedPlaybackEngineProvider);
    final isPlaybackIdle =
        engine.activeStage == PlaybackStageKind.none &&
        engine.liveNativeClientCount == 0;
    await trimIdleMemory(
      releaseIdleDevice: isPlaybackIdle,
      trimWorkingSet: true,
    );
  }

  /// 执行一次完整的缓存与原生工作集回吐。
  Future<void> trimIdleMemory({
    required bool releaseIdleDevice,
    required bool trimWorkingSet,
  }) async {
    if (_disposed) return;
    _trimManagedImageCaches(includeAudioCovers: releaseIdleDevice);
    try {
      await _ref.read(konataNativeMemoryTrimmerProvider)(
        releaseIdleDevice: releaseIdleDevice,
        trimWorkingSet: trimWorkingSet,
      );
    } catch (error) {
      debugPrint('执行平台原生内存回吐忽略：$error');
    }
  }

  void _trimManagedImageCaches({required bool includeAudioCovers}) {
    try {
      _ref.read(konataUiImageCacheTrimmerProvider)();
    } catch (error) {
      debugPrint('收缩 UI ImageCache 忽略：$error');
    }
    final artworkCacheAsync = _ref.read(artworkCacheProvider);
    if (artworkCacheAsync.hasValue) {
      artworkCacheAsync.requireValue.clearMemoryCache();
    }
    if (includeAudioCovers) {
      _ref.read(artworkMemoryCachesProvider).trimTransientCaches();
    }
  }

  /// 释放内部定时器资源。
  void dispose() {
    _disposed = true;
    _postPlaybackTimer?.cancel();
    _postPlaybackTimer = null;
  }
}

/// 全站唯一内存与图形资源回吐协调器 Provider。
final konataMemoryCoordinatorProvider = Provider<KonataMemoryCoordinator>((
  ref,
) {
  final coordinator = KonataMemoryCoordinator(ref);
  ref.onDispose(coordinator.dispose);
  return coordinator;
});
