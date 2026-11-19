part of 'immersive_audio_page.dart';

/// `ImmersiveAudioPage` 移动端布局、顶栏与歌词/队列子视口扩展。
extension _ImmersiveAudioPageStages on _ImmersiveAudioPageState {
  Widget _buildAndroidShortPhoneStage({
    required BuildContext context,
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

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 2, 14, 6),
        child: Column(
          children: [
            // 首行整体上提紧贴状态栏下方：下箭头、作品名、「歌词 / 队列」胶囊与编码徽章严格单行垂直居中对齐
            SizedBox(
              key: const ValueKey('short_phone_audio_top_bar'),
              height: KonataAdaptiveTokens.touchTarget,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    flex: 44,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        KonataCapsuleIconButton(
                          key: const ValueKey('immersive_collapse_button'),
                          icon: Icons.keyboard_arrow_down_rounded,
                          tooltip: '收起全屏播放页',
                          color: p.textPrimary,
                          size: 24,
                          fixedSize: KonataAdaptiveTokens.touchTarget,
                          onTap: _collapseToMiniBar,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            item.work.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: p.textSecondary,
                              fontSize: KonataTheme.fontSizeBodySm,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    flex: 56,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: KonataSegmentedCapsule<_ImmersiveRightPane>(
                            expand: true,
                            options: const [
                              KonataSegmentOption(
                                value: _ImmersiveRightPane.lyrics,
                                label: '歌词',
                                icon: Icons.lyrics_rounded,
                              ),
                              KonataSegmentOption(
                                value: _ImmersiveRightPane.queue,
                                label: '队列',
                                icon: Icons.queue_music_rounded,
                              ),
                            ],
                            selected: effectivePane,
                            onChanged: (next) => _mutateState(() {
                              _pane = next;
                              _userPinnedPane = true;
                            }),
                          ),
                        ),
                        if (specLabel.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          KonataSpecBadge(label: specLabel),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Expanded(
              child: Row(
                children: [
                  // 左 44%：带镜像倒影的专辑封面、仅保留当前单曲名称、进度与主控（严禁纵向溢出）
                  Expanded(
                    flex: 44,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: Center(
                            child: ImmersiveCoverWithReflection(
                              cover: cover,
                              maxCoverSize: 148,
                              borderRadius: 14,
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: p.textPrimary,
                            fontSize: KonataTheme.fontSizeTitleSm,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        ImmersiveTouchAudioScrubberLeaf(
                          notifier: notifier,
                          compact: true,
                        ),
                        LayoutBuilder(
                          builder: (context, rowConstraints) {
                            final controlsRow = Row(
                              key: const ValueKey(
                                'short_phone_audio_five_controls',
                              ),
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                KonataCapsuleIconButton(
                                  key: const ValueKey(
                                    'short_phone_audio_loop_button',
                                  ),
                                  icon: switch (loopMode) {
                                    AudioLoopMode.sequence =>
                                      Icons.trending_flat_rounded,
                                    AudioLoopMode.loopAll =>
                                      Icons.repeat_rounded,
                                    AudioLoopMode.loopOne =>
                                      Icons.repeat_one_rounded,
                                  },
                                  tooltip: '循环模式：${loopMode.label}',
                                  color: p.textPrimary,
                                  size: 20,
                                  fixedSize: KonataAdaptiveTokens.touchTarget,
                                  onTap: notifier.cycleLoopMode,
                                ),
                                KonataCapsuleIconButton(
                                  key: const ValueKey(
                                    'short_phone_audio_prev_button',
                                  ),
                                  icon: Icons.skip_previous_rounded,
                                  tooltip: '上一曲',
                                  color: p.textPrimary,
                                  size: 24,
                                  fixedSize: KonataAdaptiveTokens.touchTarget,
                                  onTap: notifier.previous,
                                ),
                                KonataCapsuleIconButton(
                                  key: const ValueKey(
                                    'short_phone_audio_play_pause_button',
                                  ),
                                  icon: isPlaying
                                      ? Icons.pause_circle_filled_rounded
                                      : Icons.play_circle_fill_rounded,
                                  tooltip: isPlaying ? '暂停' : '播放',
                                  color: p.textPrimary,
                                  size: 34,
                                  fixedSize: KonataAdaptiveTokens.touchTarget,
                                  onTap: notifier.togglePlayPause,
                                ),
                                KonataCapsuleIconButton(
                                  key: const ValueKey(
                                    'short_phone_audio_next_button',
                                  ),
                                  icon: Icons.skip_next_rounded,
                                  tooltip: '下一曲',
                                  color: p.textPrimary,
                                  size: 24,
                                  fixedSize: KonataAdaptiveTokens.touchTarget,
                                  onTap: notifier.next,
                                ),
                                KonataVolumeControl(
                                  volume: (volume / 100.0).clamp(0.0, 1.0),
                                  isMuted: isMuted,
                                  onVolumeChanged: (v) =>
                                      notifier.setVolume(v * 100.0),
                                  onToggleMute: notifier.toggleMute,
                                ),
                              ],
                            );
                            final minRowW =
                                KonataAdaptiveTokens.touchTarget * 5;
                            if (rowConstraints.maxWidth < minRowW) {
                              return FittedBox(
                                fit: BoxFit.scaleDown,
                                child: SizedBox(
                                  width: minRowW,
                                  child: controlsRow,
                                ),
                              );
                            }
                            return controlsRow;
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 14),
                  // 右 56%：全高歌词与队列（带上下渐隐）
                  Expanded(
                    flex: 56,
                    child: effectivePane == _ImmersiveRightPane.lyrics
                        ? _buildLyricsViewport(lrc, notifier, compact: true)
                        : _buildQueueViewport(snapshotState, notifier),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAndroidPortraitPhoneStage({
    required BuildContext context,
    required AudioQueueItem item,
    required LrcDocument? lrc,
    required bool hasLyrics,
    required AudioCoverSource cover,
    required bool isPlaying,
    required AudioLoopMode loopMode,
    required bool isMuted,
    required String specLabel,
    required AudioPlaybackNotifier notifier,
  }) {
    final p = context.palette;

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 顶部：支持下拉收起与左上 48dp 收起按钮
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
            child: _buildTopBar(item: item, topPadding: 2),
          ),
          // 第一段：带镜像渐变倒影的专辑封面 ↔ 滚动歌词原位淡入淡出切换
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 6),
              child: AnimatedSwitcher(
                duration: KonataTheme.motionFast,
                child: _portraitShowLyricsInPlace
                    ? KeyedSubtree(
                        key: const ValueKey('portrait_lyrics_stage'),
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: _buildLyricsViewport(
                                lrc,
                                notifier,
                                onTapEmptyArea: () => _mutateState(
                                  () => _portraitShowLyricsInPlace = false,
                                ),
                              ),
                            ),
                            Positioned(
                              top: 0,
                              right: 0,
                              child: KonataCapsuleIconButton(
                                key: const ValueKey('portrait_back_to_cover'),
                                icon: Icons.album_rounded,
                                tooltip: '返回专辑封面',
                                color: p.textSecondary,
                                size: 20,
                                fixedSize: KonataAdaptiveTokens.touchTarget,
                                onTap: () => _mutateState(
                                  () => _portraitShowLyricsInPlace = false,
                                ),
                              ),
                            ),
                          ],
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
          // 第二段：中段左对齐曲目名、音质徽章及两行实时歌词预览（不重复显示顶部已有的目录副标题）
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 4, 22, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
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
                        ),
                      ),
                    ),
                    if (specLabel.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      KonataSpecBadge(label: specLabel),
                    ],
                  ],
                ),
                if (!_portraitShowLyricsInPlace && hasLyrics) ...[
                  const SizedBox(height: 8),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () =>
                        _mutateState(() => _portraitShowLyricsInPlace = true),
                    child: const ImmersiveTwoLineLyricPreviewLeaf(),
                  ),
                ],
              ],
            ),
          ),
          // 第三段：底部进度、主控及至少 48dp 工具行（支持点击或上拉弹出播放队列抽屉）
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            onVerticalDragEnd: (details) {
              if ((details.primaryVelocity ?? 0) < -240.0) {
                _openPortraitQueueSheet();
              }
            },
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 2, 18, 10),
              child: KonataGlassCapsule(
                radius: 26,
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ImmersiveTouchAudioScrubberLeaf(notifier: notifier),
                    const SizedBox(height: 4),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        KonataCapsuleIconButton(
                          icon: Icons.skip_previous_rounded,
                          tooltip: '上一曲',
                          color: p.textPrimary,
                          size: 28,
                          fixedSize: 52,
                          onTap: notifier.previous,
                        ),
                        KonataCapsuleIconButton(
                          key: const ValueKey('portrait_audio_play_pause'),
                          icon: isPlaying
                              ? Icons.pause_circle_filled_rounded
                              : Icons.play_circle_fill_rounded,
                          tooltip: isPlaying ? '暂停' : '播放',
                          color: p.textPrimary,
                          size: 42,
                          fixedSize: 56,
                          onTap: notifier.togglePlayPause,
                        ),
                        KonataCapsuleIconButton(
                          icon: Icons.skip_next_rounded,
                          tooltip: '下一曲',
                          color: p.textPrimary,
                          size: 28,
                          fixedSize: 52,
                          onTap: notifier.next,
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    SizedBox(
                      height: KonataAdaptiveTokens.touchTarget,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
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
                            size: 20,
                            fixedSize: KonataAdaptiveTokens.touchTarget,
                            onTap: notifier.cycleLoopMode,
                          ),
                          KonataCapsuleIconButton(
                            key: const ValueKey(
                              'portrait_toggle_lyrics_button',
                            ),
                            icon: Icons.lyrics_rounded,
                            tooltip: _portraitShowLyricsInPlace
                                ? '切换专辑封面'
                                : '原位展开歌词',
                            color: p.textPrimary,
                            size: 20,
                            highlighted: _portraitShowLyricsInPlace,
                            fixedSize: KonataAdaptiveTokens.touchTarget,
                            onTap: () => _mutateState(
                              () => _portraitShowLyricsInPlace =
                                  !_portraitShowLyricsInPlace,
                            ),
                          ),
                          KonataCapsuleIconButton(
                            key: const ValueKey('portrait_open_queue_button'),
                            icon: Icons.queue_music_rounded,
                            tooltip: '上拉或点击展开播放队列',
                            color: p.textPrimary,
                            size: 21,
                            fixedSize: KonataAdaptiveTokens.touchTarget,
                            onTap: _openPortraitQueueSheet,
                          ),
                          KonataCapsuleIconButton(
                            key: const ValueKey('portrait_audio_mute_button'),
                            icon: isMuted
                                ? Icons.volume_off_rounded
                                : Icons.volume_up_rounded,
                            tooltip: isMuted ? '取消静音' : '静音',
                            color: p.textPrimary,
                            size: 20,
                            fixedSize: KonataAdaptiveTokens.touchTarget,
                            onTap: notifier.toggleMute,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopBar({
    required AudioQueueItem item,
    required double topPadding,
  }) {
    final p = context.palette;
    final isWindows = KonataAdaptiveTokens.isWindows;
    final isAndroid = KonataAdaptiveTokens.isAndroid;

    Widget headerRow = Padding(
      padding: EdgeInsets.only(top: topPadding),
      child: SizedBox(
        height: 52,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              KonataCapsuleIconButton(
                key: const ValueKey('immersive_collapse_button'),
                icon: Icons.keyboard_arrow_down_rounded,
                tooltip: '收起为迷你底栏 (Esc)',
                color: p.textPrimary,
                size: 26,
                fixedSize: isAndroid ? KonataAdaptiveTokens.touchTarget : 40,
                onTap: _collapseToMiniBar,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    EllipsisTextWithTooltip(
                      text: item.work.title,
                      style: TextStyle(
                        color: p.textPrimary,
                        fontSize: KonataTheme.fontSizeBody,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (item.albumTitle.isNotEmpty &&
                        item.albumTitle != item.work.title)
                      EllipsisTextWithTooltip(
                        text: item.albumTitle,
                        style: TextStyle(
                          color: p.textSecondary,
                          fontSize: KonataTheme.fontSizeCaptionSm,
                        ),
                      ),
                  ],
                ),
              ),
              if (isWindows) ...[
                const SizedBox(width: 8),
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

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollStartNotification &&
            notification.dragDetails != null) {
          _onUserLyricScrollActivity();
        } else if (notification is UserScrollNotification) {
          _onUserLyricScrollActivity();
        }
        return false;
      },
      child: KonataDraggableScrollbar(
        controller: _lyricScrollCtrl,
        trackInsets: const EdgeInsets.only(top: 20, bottom: 24, right: 4),
        builder: (_, ctrl) => ShaderMask(
          shaderCallback: (bounds) => const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.transparent,
              Colors.white,
              Colors.white,
              Colors.transparent,
            ],
            stops: [0.0, 0.06, 0.93, 1.0],
          ).createShader(bounds),
          blendMode: BlendMode.dstIn,
          child: ListView.builder(
            controller: ctrl,
            padding: EdgeInsets.fromLTRB(
              4,
              compact ? 14 : 28,
              22,
              compact ? 18 : 32,
            ),
            itemCount: lrc.lines.length,
            itemBuilder: (context, index) {
              final line = lrc.lines[index];
              final spanLines = ref.read(audioPlaybackProvider).activeSpanLines;
              final activeSpanLine = LyricVersionMatcher.matchLineForTimestamp(
                spanLines,
                line.startSeconds,
              );
              return KeyedSubtree(
                key: _lyricKeys[index],
                child: ImmersiveLyricLineLeaf(
                  index: index,
                  line: line,
                  activeSpanLine: activeSpanLine,
                  compact: compact,
                  userScrolling: _isUserScrollingLyrics,
                  onSeekLine: () {
                    _scrollResetTimer?.cancel();
                    _mutateState(() => _isUserScrollingLyrics = false);
                    notifier.seekRelativeTrackSeconds(line.startSeconds);
                  },
                ),
              );
            },
          ),
        ),
      ),
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
      trackInsets: const EdgeInsets.only(top: 16, bottom: 20, right: 4),
      builder: (_, ctrl) => ShaderMask(
        shaderCallback: (bounds) => const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.transparent,
            Colors.white,
            Colors.white,
            Colors.transparent,
          ],
          stops: [0.0, 0.04, 0.95, 1.0],
        ).createShader(bounds),
        blendMode: BlendMode.dstIn,
        child: ListView.separated(
          controller: ctrl,
          padding: const EdgeInsets.fromLTRB(4, 16, 22, 24),
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
