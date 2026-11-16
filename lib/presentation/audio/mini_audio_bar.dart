import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/playback/audio_playback_notifier.dart';
import '../../application/playback/playback_preferences_provider.dart';
import '../../application/providers/artwork_provider.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_playback_tokens.dart';
import '../widgets/managed_image.dart';
import '../widgets/playback/konata_playback_capsule.dart';
import '../widgets/playback/konata_spec_badge.dart';
import '../widgets/playback/konata_volume_control.dart';
import 'immersive_audio_page.dart';

/// 当持久迷你音频底栏处于可视状态时，供底部滚动视图预留防遮挡留白的高度 Provider。
final miniAudioBottomClearanceProvider = Provider<double>((ref) {
  final audio = ref.watch(audioPlaybackProvider);
  final videoActive = ref.watch(videoPlaybackActiveProvider);
  final expanded = ref.watch(immersiveAudioExpandedProvider);
  final visible = audio.isActive && !videoActive && !expanded;
  return visible ? KonataPlaybackTokens.miniBarClearanceHeight : 0.0;
});

/// 挂载在 `MaterialApp.builder` 的全局音频宿主（提供合法根级 [Overlay] 祖先，杜绝 Tooltip/Toast 缺失异常，
/// 并确保内置视频页打开时自动隐藏迷你栏且全程零指针拦截）。
class MiniAudioOverlayHost extends StatefulWidget {
  /// 创建全局音频叠加宿主。
  const MiniAudioOverlayHost({super.key, required this.child});

  /// 被包裹的根 `Navigator` 子树。
  final Widget child;

  @override
  State<MiniAudioOverlayHost> createState() => _MiniAudioOverlayHostState();
}

class _MiniAudioOverlayHostState extends State<MiniAudioOverlayHost> {
  late final OverlayEntry _rootEntry;

  @override
  void initState() {
    super.initState();
    _rootEntry = OverlayEntry(
      maintainState: true,
      builder: (_) => Stack(
        fit: StackFit.expand,
        children: [widget.child, const _GlobalAudioOverlayLayer()],
      ),
    );
  }

  @override
  void didUpdateWidget(covariant MiniAudioOverlayHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.child != widget.child) {
      _rootEntry.markNeedsBuild();
    }
  }

  @override
  void dispose() {
    _rootEntry.remove();
    _rootEntry.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Overlay(initialEntries: [_rootEntry]);
  }
}

class _GlobalAudioOverlayLayer extends ConsumerWidget {
  const _GlobalAudioOverlayLayer();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final audioState = ref.watch(audioPlaybackProvider);
    final videoActive = ref.watch(videoPlaybackActiveProvider);
    final expanded = ref.watch(immersiveAudioExpandedProvider);

    if (!audioState.isActive || videoActive) {
      return const SizedBox.shrink();
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        // 持久浮动毛玻璃迷你底栏（沉浸页未展开时显示）
        AnimatedPositioned(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          left: KonataPlaybackTokens.miniBarHorizontalInset,
          right: KonataPlaybackTokens.miniBarHorizontalInset,
          bottom: expanded
              ? -(KonataPlaybackTokens.miniBarHeight + 36)
              : KonataPlaybackTokens.miniBarBottomInset,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 180),
            opacity: expanded ? 0.0 : 1.0,
            child: IgnorePointer(
              ignoring: expanded,
              child: const Center(child: MiniAudioBar()),
            ),
          ),
        ),
        // 全屏流光倒影沉浸音频页
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 260),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          child: expanded
              ? const ImmersiveAudioPage(key: ValueKey('immersive_audio'))
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

/// 全局持久 CD / 无损音乐悬浮毛玻璃迷你底栏（直接复用 [KonataPlaybackCapsule]）。
class MiniAudioBar extends ConsumerWidget {
  /// 创建迷你音频底栏。
  const MiniAudioBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final state = ref.watch(audioPlaybackProvider);
    final notifier = ref.read(audioPlaybackProvider.notifier);
    final item = state.currentItem;
    if (item == null) return const SizedBox.shrink();

    void openImmersive() {
      ref.read(immersiveAudioExpandedProvider.notifier).state = true;
    }

    final specLabel = state.audioCodecLabel.isNotEmpty
        ? (state.sampleRateAndBitDepthLabel.isNotEmpty
              ? '${state.audioCodecLabel} · ${state.sampleRateAndBitDepthLabel}'
              : state.audioCodecLabel)
        : '';

    return KonataPlaybackCapsule(
      forceOnDarkOverlay: false,
      leading: _MiniCoverThumbnail(cover: state.cover, size: 38),
      title: item.title,
      onTapInfo: openImmersive,
      positionSeconds: state.positionSeconds,
      durationSeconds: state.durationSeconds,
      isPlaying: state.isPlaying,
      onTogglePlayPause: notifier.togglePlayPause,
      onSeek: notifier.seekRelativeTrackSeconds,
      onPrevious: notifier.previous,
      onNext: notifier.next,
      onToggleList: openImmersive,
      listTooltip: '展开全屏流光与专辑曲目',
      rightSlot: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (specLabel.isNotEmpty) ...[
            KonataSpecBadge(label: specLabel),
            const SizedBox(width: 4),
          ],
          KonataVolumeControl(
            volume: (state.volume / 100.0).clamp(0.0, 1.0),
            isMuted: state.isMuted,
            onVolumeChanged: (v) => notifier.setVolume(v * 100.0),
            onToggleMute: notifier.toggleMute,
            forceOnDarkOverlay: false,
          ),
          KonataCapsuleIconButton(
            icon: Icons.open_in_full_rounded,
            tooltip: '展开全屏流光页',
            size: 16,
            color: p.textSecondary,
            onTap: openImmersive,
          ),
          KonataCapsuleIconButton(
            icon: Icons.close_rounded,
            tooltip: '停止并关闭音乐栏',
            size: 17,
            color: p.textMuted,
            onTap: notifier.stopAndClose,
          ),
        ],
      ),
    );
  }
}

class _MiniCoverThumbnail extends ConsumerWidget {
  const _MiniCoverThumbnail({required this.cover, this.size = 38});

  final AudioCoverSource cover;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final loader = ref.watch(tmdbImageLoaderProvider);

    Widget content;
    switch (cover) {
      case MemoryAudioCover(:final bytes):
        content = Image.memory(
          bytes,
          width: size,
          height: size,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.medium,
          gaplessPlayback: true,
        );
      case ManagedPosterAudioCover(:final url, :final workId):
        content = ManagedImage(
          url,
          loader: loader,
          owner: workId,
          width: size,
          height: size,
          decodeWidth: 256,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _fallbackTile(p),
        );
      case EmptyAudioCover():
        content = _fallbackTile(p);
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(9),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          border: Border.all(color: p.hairline, width: 1),
          borderRadius: BorderRadius.circular(9),
        ),
        child: content,
      ),
    );
  }

  Widget _fallbackTile(KonataPalette p) {
    return Container(
      width: size,
      height: size,
      color: p.softFill,
      alignment: Alignment.center,
      child: Icon(Icons.music_note_rounded, size: 18, color: p.textSecondary),
    );
  }
}
