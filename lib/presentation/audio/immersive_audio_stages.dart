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
                child: _portraitShowLyricsInPlace
                    ? KeyedSubtree(
                        key: const ValueKey('portrait_lyrics_stage'),
                        child: _buildLyricsViewport(
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
    LrcDocument? lrc,
    AudioPlaybackNotifier notifier, {
    bool compact = false,
    bool centerAligned = false,
    VoidCallback? onTapEmptyArea,
  }) {
    final p = context.palette;
    if (lrc == null || lrc.lines.isEmpty) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTapEmptyArea,
        child: Center(
          child: Consumer(
            builder: (ctx, cRef, _) {
              final needsAmllConfirm = cRef.watch(
                audioPlaybackProvider.select(
                  (s) => s.needsMobileAmllLyricConfirmation,
                ),
              );
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.lyrics_outlined, size: 40, color: p.textMuted),
                  const SizedBox(height: 12),
                  Text(
                    needsAmllConfirm
                        ? '当前处于移动计量网络，拉取 AMLL 逐字歌词索引需消耗流量'
                        : '当前曲目暂无同步歌词',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: p.textSecondary, fontSize: KonataTheme.fontSizeBodyMd),
                  ),
                  if (needsAmllConfirm) ...[
                    const SizedBox(height: 12),
                    KonataPillButton.primary(
                      key: const ValueKey('confirm_mobile_amll_lyric_button'),
                      label: '允许加载 AMLL 歌词',
                      icon: Icons.cloud_download_outlined,
                      compact: true,
                      onPressed: () =>
                          unawaited(notifier.confirmMobileAmllLyricLookup()),
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportH = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : 480.0;
        final anchorRatio = compact
            ? KonataPlaybackTokens.lyricCompactViewportAnchorRatio
            : KonataPlaybackTokens.lyricViewportAnchorRatio;
        final guideH = compact
            ? KonataPlaybackTokens.lyricScrubCompactGuideHeight
            : KonataPlaybackTokens.lyricScrubGuideHeight;
        final minAnchor = math.min(viewportH * 0.5, compact ? 44.0 : 84.0);
        final maxAnchor = math.max(minAnchor, viewportH - (compact ? 48.0 : 88.0));
        final anchorY = (viewportH * anchorRatio).clamp(minAnchor, maxAnchor);
        final topSpacer = math.max(12.0, anchorY - guideH * 0.5);
        final bottomSpacer = math.max(24.0, viewportH - anchorY - guideH * 0.5);
        final scrubIdx = _isUserScrollingLyrics
            ? (_scrubTargetLyricIndex ??
                      (_lastActiveLyricIndex >= 0 ? _lastActiveLyricIndex : 0))
                  .clamp(0, lrc.lines.length - 1)
            : null;
        final scrubLine = scrubIdx != null ? lrc.lines[scrubIdx] : null;
        final scrubSettled =
            scrubLine != null && !_lyricScrollActivelyDragging;
        final isAndroid = KonataAdaptiveTokens.isAndroid;
        final playButtonSize = isAndroid
            ? KonataAdaptiveTokens.touchTarget
            : 36.0;
        final listPadLeft = compact ? 48.0 : 54.0;
        final listPadRight = isAndroid ? 50.0 : 42.0;

        return SizedBox(
          key: _lyricViewportKey,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // 三端统一隐藏歌词滚动条，禁止直接点击单句跳播；改为上下滚动唤出中央时间轴定位跳转。
              Positioned.fill(
                child: Listener(
                  onPointerSignal: (event) {
                    if (event is PointerScrollEvent) {
                      _onUserLyricScrollActivity(
                        lrc,
                        anchorRatio,
                        activeDrag: true,
                      );
                    }
                  },
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: onTapEmptyArea == null
                        ? null
                        : () {
                            if (_isUserScrollingLyrics) {
                              _cancelUserLyricScrub();
                            }
                            onTapEmptyArea();
                          },
                    child: NotificationListener<ScrollNotification>(
                      onNotification: (notification) {
                        if (notification is ScrollStartNotification) {
                          if (notification.dragDetails != null ||
                              !_programmaticLyricScroll) {
                            _onUserLyricScrollActivity(
                              lrc,
                              anchorRatio,
                              activeDrag: true,
                            );
                          }
                        } else if (notification is UserScrollNotification) {
                          if (notification.direction != ScrollDirection.idle) {
                            _onUserLyricScrollActivity(
                              lrc,
                              anchorRatio,
                              activeDrag: true,
                            );
                          }
                        } else if (notification is ScrollUpdateNotification) {
                          if (!_programmaticLyricScroll &&
                              (notification.dragDetails != null ||
                                  _isUserScrollingLyrics)) {
                            _onUserLyricScrollActivity(
                              lrc,
                              anchorRatio,
                              activeDrag: true,
                            );
                          }
                        } else if (notification is ScrollEndNotification) {
                          if (_isUserScrollingLyrics) {
                            _onUserLyricScrollEnded(lrc, anchorRatio);
                          }
                        }
                        return false;
                      },
                      child: ScrollConfiguration(
                        behavior: ScrollConfiguration.of(
                          context,
                        ).copyWith(scrollbars: false),
                        child: ShaderMask(
                          shaderCallback: (bounds) => const LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.transparent,
                              KonataTheme.pureWhite,
                              KonataTheme.pureWhite,
                              Colors.transparent,
                            ],
                            stops: [0.0, 0.10, 0.88, 1.0],
                          ).createShader(bounds),
                          blendMode: BlendMode.dstIn,
                          child: ListView.builder(
                            key: const ValueKey('immersive_lyrics_list'),
                            controller: _lyricScrollCtrl,
                            padding: EdgeInsets.fromLTRB(
                              listPadLeft,
                              topSpacer,
                              listPadRight,
                              bottomSpacer,
                            ),
                            itemCount: lrc.lines.length,
                            itemBuilder: (context, index) {
                              final line = lrc.lines[index];
                              final nextStart = index + 1 < lrc.lines.length
                                  ? lrc.lines[index + 1].startSeconds
                                  : null;
                              final songPaceSecPerChar =
                                  lrc.estimatedSecondsPerChar;
                              final spanLines = ref
                                  .read(audioPlaybackProvider)
                                  .activeSpanLines;
                              final activeSpanLine =
                                  LyricVersionMatcher.matchLineForTimestamp(
                                    spanLines,
                                    line.startSeconds,
                                  );
                              return KeyedSubtree(
                                key: _lyricKeys[index],
                                child: ImmersiveLyricLineLeaf(
                                  index: index,
                                  line: line,
                                  activeSpanLine: activeSpanLine,
                                  nextLineStartSeconds: nextStart,
                                  estimatedSecondsPerChar: songPaceSecPerChar,
                                  compact: compact,
                                  centerAligned: centerAligned,
                                  userScrolling: _isUserScrollingLyrics,
                                  isScrubFocused: scrubIdx == index,
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // 中央时间轴定位层：滚动中呈现左侧时间戳 + 细横线 + 右侧播放键；停顿后亮起柔光定位条，点击定位条或播放键即可跳转。
              if (scrubLine != null)
                Positioned(
                  key: const ValueKey('lyric_timeline_scrub_guide'),
                  left: 0,
                  right: 0,
                  top: (anchorY - guideH * 0.5).clamp(
                    0.0,
                    math.max(0.0, viewportH - guideH),
                  ),
                  height: guideH,
                  child: AnimatedContainer(
                    duration: KonataTheme.motionFast,
                    curve: Curves.easeOutCubic,
                    decoration: BoxDecoration(
                      color: scrubSettled
                          ? p.textPrimary.withValues(
                              alpha: p.isDark ? 0.11 : 0.08,
                            )
                          : Colors.transparent,
                      borderRadius: KonataTheme.borderRadiusCard,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        IgnorePointer(
                          child: SizedBox(
                            width: KonataPlaybackTokens.lyricScrubTimeWidth,
                            child: Text(
                              PlaybackFormatters.formatMediaDuration(
                                scrubLine.startSeconds,
                              ),
                              key: const ValueKey(
                                'lyric_timeline_scrub_timestamp',
                              ),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: p.textSecondary.withValues(alpha: 0.9),
                                fontSize: KonataTheme.fontSizeCaption,
                                fontWeight: FontWeight.w500,
                                fontFeatures:
                                    KonataPlaybackTokens.tabularNumbers,
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          child: scrubSettled
                              ? GestureDetector(
                                  key: const ValueKey(
                                    'lyric_timeline_seek_band',
                                  ),
                                  behavior: HitTestBehavior.translucent,
                                  onTap: () => _commitScrubSeek(lrc, notifier),
                                  child: const SizedBox.expand(),
                                )
                              : IgnorePointer(
                                  child: Center(
                                    child: Container(
                                      height: 0.8,
                                      margin: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                      ),
                                      color: p.textPrimary.withValues(
                                        alpha: p.isDark ? 0.18 : 0.15,
                                      ),
                                    ),
                                  ),
                                ),
                        ),
                        MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: GestureDetector(
                            key: const ValueKey(
                              'lyric_timeline_seek_play_button',
                            ),
                            behavior: HitTestBehavior.opaque,
                            onTap: () => _commitScrubSeek(lrc, notifier),
                            child: SizedBox.square(
                              dimension: playButtonSize,
                              child: Center(
                                child: Icon(
                                  Icons.play_arrow_rounded,
                                  size: 20,
                                  color: p.textPrimary.withValues(alpha: 0.9),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        );
      },
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
