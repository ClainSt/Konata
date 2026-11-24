import 'dart:async';

/// Android 根窗口底层（Underlay）硬件表面变化快照。
class AndroidSurfaceDescriptor {
  /// 创建 Android 表面状态快照。
  const AndroidSurfaceDescriptor({
    required this.wid,
    required this.width,
    required this.height,
    required this.hdrPeak,
  });

  /// 绑定给 `libmpv` `wid` 选项的 `MediaKitAndroidHelper` 全局引用句柄。
  final int wid;

  /// 当前表面像素宽。
  final int width;

  /// 当前表面像素高。
  final int height;

  /// 屏幕硬件 HDR 峰值（nits，未知时为 0）。
  final double hdrPeak;
}

/// Android 10-bit 根窗口底层硬件表面控制端口（纯 Dart 抽象，由上层注入原生平台实现）。
abstract interface class AndroidVideoSurfacePort {
  /// 当前已知表面描述符（若已销毁或尚未创建则为 `null`）。
  AndroidSurfaceDescriptor? get current;

  /// 表面就绪、尺寸变更或销毁丢失通知流。
  Stream<AndroidSurfaceDescriptor?> get surfaceChanges;

  /// 当前已释放标识。
  bool get isDisposed;

  /// 显示并同步底层表面在物理像素坐标系下的矩形与圆角半径。
  Future<void> syncViewportRect({
    required int leftPx,
    required int topPx,
    required int rightPx,
    required int bottomPx,
    double cornerRadiusPx = 0.0,
  });

  /// 隐藏底层表面（纯音频模式或退出播放时立即释放系统缓冲）。
  Future<void> hideViewport();

  /// 主动向原生端查询当前可用表面信息（句柄与宽高均需大于 0）。
  Future<AndroidSurfaceDescriptor?> queryCurrent();

  /// 在 `libmpv` 解绑 `vo=null` / `wid=0` 后精确释放指定旧表面的全局引用。
  Future<void> releaseReference(int wid);

  /// 隐藏底层表面并释放与当前会话关联的全部表面引用。
  Future<void> releaseSurface();

  /// 热重绑交接给新控制器时仅关闭自身事件流，保留底层通道监听器不被误清零。
  Future<void> detachWithoutClearingChannel();

  /// 注销通道监听器并关闭事件流。
  Future<void> dispose();
}
