import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// 音频舞台向外挂歌词模块开放的只读视口注入上下文。
///
/// 通过叶子位置监听源与跳转回调解耦音频内核和具体歌词渲染实现，
/// 确保未挂载歌词模块时音频舞台可零错误独立运行。
final class AudioLyricsViewportContext {
  /// 构造歌词视口渲染上下文。
  const AudioLyricsViewportContext({
    required this.trackKey,
    required this.positionListenable,
    required this.isPlayingListenable,
    required this.onSeekTo,
    this.compact = false,
    this.centerAligned = false,
    this.onTapEmptyArea,
  });

  /// 当前正在播放曲目的唯一定位键。
  final String trackKey;

  /// 当前逻辑曲目叶子播放位置监听源。
  final ValueListenable<Duration> positionListenable;

  /// 当前叶子播放/暂停状态监听源。
  final ValueListenable<bool> isPlayingListenable;

  /// 点击歌词行触发曲内精确跳转的回调函数。
  final Future<void> Function(Duration position) onSeekTo;

  /// 是否启用紧凑字号与锚点比例（如矮视口手机横屏）。
  final bool compact;

  /// 是否启用居中对齐文本样式（如手机竖屏歌词页）。
  final bool centerAligned;

  /// 点击空白歌词区域时的快捷切回回调（常用于竖屏封面切换）。
  final VoidCallback? onTapEmptyArea;
}

/// 音频舞台可选外挂歌词视图构建器签名。
typedef AudioLyricsViewportBuilder =
    Widget Function(BuildContext context, AudioLyricsViewportContext viewport);
