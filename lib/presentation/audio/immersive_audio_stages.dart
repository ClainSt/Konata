part of 'immersive_audio_page.dart';

/// `ImmersiveAudioPage` 移动端布局、顶栏与歌词/队列子视口扩展。
extension _ImmersiveAudioPageStages on _ImmersiveAudioPageState {
  Widget _buildAndroidShortPhoneStage({
    required BuildContext context,
    required EdgeInsets safe,
    required AudioQueueItem item,
    required LrcDocument? lrc,
    required AudioCoverSource cover,
    required bool isPlaying,
    required AudioLoopMode loopMode,
    required double volume,
    required bool isMuted,
    required String specLabel,
    required _ImmersiveRightPane effectivePane,
    required AudioPlaybackNotifier notifier,
  }) {
    final p = context.palette;
    final snapshotState = ref.read(audioPlaybackProvider);
    final screenSize = MediaQuery.sizeOf(context);
    final maxCoverSize = (screenSize.height * 0.44).clamp(108.0, 172.0);
    final capsuleMaxW = math.min(
      KonataAdaptiveTokens.tabletPlayerMaxWidth,
      math.max(320.0, screenSize.width - safe.horizontal - 24.0),
    );

    final togglePaneButton = KonataCapsuleIconButton(
      key: const ValueKey('immersive_toggle_pane_button'),
      icon: effectivePane == _ImmersiveRightPane.queue
          ? Icons.lyrics_rounded
          : Icons.queue_music_rounded,
      tooltip: effectivePane == _ImmersiveRightPane.queue
          ? '切换至同步歌词'
          : '切换至专辑曲目列表',
      color: p.textPrimary,
      size: 20,
      fixedSize: KonataAdaptiveTokens.touchTarget,
      borderRadius: KonataPlaybackTokens.immersiveSwitchButtonRadius,
      padding: EdgeInsets.zero,
      highlighted: effectivePane == _ImmersiveRightPane.queue,
      highlightColor: p.textPrimary,
      highlightBgColor: KonataPlaybackTokens.activePillBg(p),
      showHighlightBorder: false,
      onTap: () => _mutateState(() {
        _pane = effectivePane == _ImmersiveRightPane.queue
            ? _ImmersiveRightPane.lyrics
            : _ImmersiveRightPane.queue;
        _userPinnedPane = true;
      }),
    );

    return Padding(
      padding: EdgeInsets.fromLTRB(
        math.max(safe.left, 16.0),
        math.max(safe.top, 4.0),
        math.max(safe.right, 16.0),
        math.max(safe.bottom, 6.0),
      ),
      child: Column(
        children: [
          // 手机横屏沿用桌面/平板同源双栏 + 底部居中光学长胶囊，顶栏仅保留收起按钮保持通透。
          SizedBox(
            key: const ValueKey('short_phone_audio_top_bar'),
            height: 40,
            child: Row(
              children: [
                KonataCapsuleIconButton(
                  key: const ValueKey('immersive_collapse_button'),
                  icon: Icons.keyboard_arrow_down_rounded,
                  tooltip: '收起全屏播放页',
                  color: p.textSecondary,
                  size: 24,
                  fixedSize: KonataAdaptiveTokens.touchTarget,
                  onTap: _collapseToMiniBar,
                ),
                const Spacer(),
              ],
            ),
          ),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  flex: 4,
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: ImmersiveCoverWithReflection(
                        cover: cover,
                        maxCoverSize: maxCoverSize,
                        borderRadius: 14,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  flex: 6,
                  child: KonataSmoothSectionSwitcher(
                    switchKey: effectivePane,
                    alignment: Alignment.center,
                    child: effectivePane == _ImmersiveRightPane.lyrics
                        ? KeyedSubtree(
                            key: const ValueKey('short_phone_lyrics_pane'),
                            child: _buildLyricsViewport(
                              item.id,
                              lrc,
                              notifier,
                              compact: true,
                            ),
                          )
                        : KeyedSubtree(
                            key: const ValueKey('short_phone_queue_pane'),
                            child: _buildQueueViewport(snapshotState, notifier),
                          ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Center(
            child: ImmersiveAudioCapsuleDockLeaf(
              maxWidth: capsuleMaxW,
              title: item.title,
              isPlaying: isPlaying,
              loopMode: loopMode,
              notifier: notifier,
              trailingCenterPrimaryButton: togglePaneButton,
              rightSlot: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (specLabel.isNotEmpty &&
                      screenSize.width >=
                          KonataPlaybackTokens.miniBarHideBadgeBreakpoint) ...[
                    KonataSpecBadge(label: specLabel),
                    const SizedBox(width: 6),
                  ],
                  KonataVolumeControl(
                    volume: (volume / 100.0).clamp(0.0, 1.0),
                    isMuted: isMuted,
                    onVolumeChanged: (v) => notifier.setVolume(v * 100.0),
                    onToggleMute: notifier.toggleMute,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAndroidPortraitPhoneStage({
    required BuildContext context,
    required AudioQueueItem item,
    required LrcDocument? lrc,
    required AudioCoverSource cover,
    required bool isPlaying,
    required AudioLoopMode loopMode,
    required String specLabel,
    required AudioPlaybackNotifier notifier,
  }) {
    final p = context.palette;

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 顶部极简留白：支持下拉收起与左上 48dp 收起按钮
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragStart: (_) => _pullDownDy = 0.0,
            onVerticalDragUpdate: (details) {
              if (details.delta.dy > 0) {
                _pullDownDy += details.delta.dy;
              }
            },
            onVerticalDragEnd: (details) {
              final velocity = details.primaryVelocity ?? 0.0;
              if (_pullDownDy > 48.0 || velocity > 420.0) {
                _collapseToMiniBar(releaseVelocityPxPerSec: velocity);
              }
              _pullDownDy = 0.0;
            },
            child: _buildTopBar(topPadding: 2),
          ),
          // 第一段：带柔雾镜像倒影的专辑封面 ↔ 滚动歌词原位淡入淡出切换（轻触封面直达歌词）
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: AnimatedSwitcher(
                duration: KonataTheme.motionFast,
                transitionBuilder: (child, animation) => AnimatedBuilder(
                  animation: animation,
                  child: child,
                  builder: (_, inner) {
                    final isOutgoing =
                        animation.status == AnimationStatus.reverse;
                    return IgnorePointer(
                      ignoring: isOutgoing,
                      child: TickerMode(
                        enabled: !isOutgoing,
                        child: FadeTransition(
                          opacity: animation,
                          child: inner,
                        ),
                      ),
                    );
                  },
                ),
                child: _portraitShowLyricsInPlace
                    ? KeyedSubtree(
                        key: const ValueKey('portrait_lyrics_stage'),
                        child: _buildLyricsViewport(
                          item.id,
                          lrc,
                          notifier,
                          centerAligned: true,
                          onTapEmptyArea: () => _mutateState(
                            () => _portraitShowLyricsInPlace = false,
                          ),
                        ),
                      )
                    : KeyedSubtree(
                        key: const ValueKey('portrait_cover_stage'),
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => _mutateState(
                            () => _portraitShowLyricsInPlace = true,
                          ),
                          onVerticalDragStart: (_) => _pullDownDy = 0.0,
                          onVerticalDragUpdate: (d) {
                            if (d.delta.dy > 0) _pullDownDy += d.delta.dy;
                          },
                          onVerticalDragEnd: (d) {
                            final velocity = d.primaryVelocity ?? 0.0;
                            if (_pullDownDy > 54.0 || velocity > 460.0) {
                              _collapseToMiniBar(
                                releaseVelocityPxPerSec: velocity,
                              );
                            }
                            _pullDownDy = 0.0;
                          },
                          child: Center(
                            child: ImmersiveCoverWithReflection(
                              cover: cover,
                              maxCoverSize: 340,
                            ),
                          ),
                        ),
                      ),
              ),
            ),
          ),
          // 第二段：极简曲目名与音质规格微标（去冗余双行歌词预览，保持通透呼吸感）
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 6, 24, 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: p.textPrimary,
                      fontSize: KonataTheme.fontSizeH2,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.2,
                    ),
                  ),
                ),
                if (specLabel.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  KonataSpecBadge(label: specLabel),
                ],
              ],
            ),
          ),
          // 第三段：悬浮细进度滑轨 + 无框平铺五键播控行（对齐网易云音乐布局，去掉底框胶囊与圆形实心底）
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ImmersiveTouchAudioScrubberLeaf(notifier: notifier),
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      KonataCapsuleIconButton(
                        key: const ValueKey('portrait_audio_loop_button'),
                        icon: switch (loopMode) {
                          AudioLoopMode.sequence =>
                            Icons.trending_flat_rounded,
                          AudioLoopMode.loopAll => Icons.repeat_rounded,
                          AudioLoopMode.loopOne => Icons.repeat_one_rounded,
                        },
                        tooltip: '循环模式：${loopMode.label}',
                        color: p.textPrimary,
                        size: 22,
                        fixedSize: KonataAdaptiveTokens.touchTarget,
                        onTap: notifier.cycleLoopMode,
                      ),
                      KonataCapsuleIconButton(
                        key: const ValueKey('portrait_audio_prev_button'),
                        icon: Icons.skip_previous_rounded,
                        tooltip: '上一曲',
                        color: p.textPrimary,
                        size: 30,
                        fixedSize: KonataAdaptiveTokens.touchTarget,
                        onTap: notifier.previous,
                      ),
                      Tooltip(
                        message: isPlaying ? '暂停' : '播放',
                        child: GestureDetector(
                          key: const ValueKey('portrait_audio_play_pause'),
                          behavior: HitTestBehavior.opaque,
                          onTap: notifier.togglePlayPause,
                          child: SizedBox.square(
                            dimension: 56,
                            child: Center(
                              child: Icon(
                                isPlaying
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded,
                                size: 42,
                                color: p.textPrimary,
                              ),
                            ),
                          ),
                        ),
                      ),
                      KonataCapsuleIconButton(
                        key: const ValueKey('portrait_audio_next_button'),
                        icon: Icons.skip_next_rounded,
                        tooltip: '下一曲',
                        color: p.textPrimary,
                        size: 30,
                        fixedSize: KonataAdaptiveTokens.touchTarget,
                        onTap: notifier.next,
                      ),
                      KonataCapsuleIconButton(
                        key: const ValueKey('portrait_open_queue_button'),
                        icon: Icons.queue_music_rounded,
                        tooltip: '展开播放队列',
                        color: p.textPrimary,
                        size: 22,
                        fixedSize: KonataAdaptiveTokens.touchTarget,
                        onTap: _openPortraitQueueSheet,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopBar({required double topPadding}) {
    final p = context.palette;
    final isWindows = KonataAdaptiveTokens.isWindows;
    final isAndroid = KonataAdaptiveTokens.isAndroid;
    final canRelayExternal =
        isWindows && ref.watch(desktopRelayGatewayProvider) != null;

    Widget headerRow = Padding(
      padding: EdgeInsets.only(top: topPadding),
      child: SizedBox(
        height: 48,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              KonataCapsuleIconButton(
                key: const ValueKey('immersive_collapse_button'),
                icon: Icons.keyboard_arrow_down_rounded,
                tooltip: '收起全屏播放页 (Esc)',
                color: p.textSecondary,
                size: 24,
                fixedSize: isAndroid ? KonataAdaptiveTokens.touchTarget : 38,
                onTap: _collapseToMiniBar,
              ),
              const Spacer(),
              if (canRelayExternal) ...[
                KonataCapsuleIconButton(
                  key: const ValueKey('immersive_relay_external_button'),
                  icon: Icons.open_in_new_rounded,
                  tooltip: '使用外部播放器继续播放',
                  color: p.textSecondary,
                  size: 18,
                  fixedSize: 36,
                  onTap: () => unawaited(
                    ExternalAudioRelayUiHelper.dispatchWithGuide(
                      context: context,
                      ref: ref,
                      action: ({required forceAllowWithoutBeefweb}) => ref
                          .read(playbackDispatcherProvider)
                          .relayActiveBuiltinAudioToDesktop(
                            forceAllowWithoutBeefweb: forceAllowWithoutBeefweb,
                          ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
              ],
              if (isWindows) ...[
                ref.read(konataWindowHostProvider).buildWindowControls(),
              ],
            ],
          ),
        ),
      ),
    );

    if (isWindows) {
      headerRow = ref
          .read(konataWindowHostProvider)
          .buildDragToMoveArea(child: headerRow);
    }
    return headerRow;
  }

  Widget _buildLyricsViewport(
    String itemId,
    LrcDocument? lrc,
    AudioPlaybackNotifier notifier, {
    bool compact = false,
    bool centerAligned = false,
    VoidCallback? onTapEmptyArea,
  }) {
    return ImmersiveLyricsViewport(
      itemId: itemId,
      lrc: lrc,
      notifier: notifier,
      compact: compact,
      centerAligned: centerAligned,
      onTapEmptyArea: onTapEmptyArea,
    );
  }

  Widget _buildQueueViewport(
    AudioPlaybackState state,
    AudioPlaybackNotifier notifier, {
    VoidCallback? onPicked,
  }) {
    final displayRows = state.buildDisplayRows();
    return KonataDraggableScrollbar(
      controller: _queueScrollCtrl,
      trackInsets: const EdgeInsets.only(top: 24, bottom: 32, right: 4),
      builder: (_, ctrl) => ShaderMask(
        shaderCallback: (bounds) => const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.transparent,
            KonataTheme.pureWhite,
            KonataTheme.pureWhite,
            Colors.transparent,
          ],
          stops: [0.0, 0.06, 0.94, 1.0],
        ).createShader(bounds),
        blendMode: BlendMode.dstIn,
        child: ListView.separated(
          controller: ctrl,
          padding: const EdgeInsets.fromLTRB(4, 24, 22, 32),
          itemCount: displayRows.length,
          separatorBuilder: (_, _) => const SizedBox(height: 6),
          itemBuilder: (context, index) {
            final row = displayRows[index];
            return ImmersiveBorderlessQueueRow(
              key: row.isActiveTrack
                  ? _activeQueueItemKey
                  : ValueKey('q_row_${row.id}'),
              row: row,
              isPlaying: row.isActiveTrack && state.isPlaying,
              onTap: () {
                notifier.playQueueIndex(row.targetQueueIndex);
                onPicked?.call();
              },
            );
          },
        ),
      ),
    );
  }
}
