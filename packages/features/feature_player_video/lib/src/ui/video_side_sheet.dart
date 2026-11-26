import 'dart:async';
import 'dart:math' as math;

import 'package:engine_playback/engine_playback.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';
import 'package:konata_storage/konata_storage.dart';

import '../data/video_playback_preferences.dart';
import '../data/video_session_models.dart';
import '../state/video_playback_controller.dart';
import '../state/video_playback_state.dart';

import 'video_audio_route_controls.dart';
import 'video_playback_capsule.dart';

part 'video_side_sheet_sections.dart';
part 'video_side_sheet_track_widgets.dart';

/// 右滑视频设置与剧集选择侧栏默认内置页签枚举。
enum VideoSideSheetTab {
  /// 剧集与系列切季列表。
  episodes('选集'),

  /// 内嵌章节定位清单。
  chapters('章节'),

  /// 内封与外挂字幕管理。
  subtitles('字幕'),

  /// 音轨与输出设备控制。
  audio('音频'),

  /// 画面填充、比例与着色器控制。
  video('画面');

  const VideoSideSheetTab(this.label);

  /// 界面展示页签名称。
  final String label;
}

/// 视频右滑浮层侧栏（动态挂载符合视频媒体模式且适配当前平台的扩展侧栏贡献）。
class VideoSideSheet extends StatefulWidget {
  /// 创建视频控制侧滑栏。
  const VideoSideSheet({
    super.key,
    required this.controller,
    required this.initialTab,
    required this.onClose,
    this.playerSidePanels = const <PlayerSidePanelContribution>[],
    this.initialContributionId,
  });

  /// 视频播放核心控制器。
  final VideoPlaybackController controller;

  /// 打开侧栏时的默认选中页签。
  final VideoSideSheetTab initialTab;

  /// 关闭侧栏回调。
  final VoidCallback onClose;

  /// 外部业务模块声明并经平台过滤后的侧栏扩展贡献列表。
  final List<PlayerSidePanelContribution> playerSidePanels;

  /// 可选初始聚焦的外部贡献面板标识。
  final String? initialContributionId;

  @override
  State<VideoSideSheet> createState() => _VideoSideSheetState();
}

class _VideoSideSheetState extends State<VideoSideSheet> {
  static const String _contribPrefix = 'contrib::';
  late String _selectedKey;
  late Stream<VideoPlaybackPreferences> _prefsStream;

  List<PlayerSidePanelContribution> get _supportedPanels {
    final platform = widget.controller.env.platform;
    final matched = <PlayerSidePanelContribution>[
      for (final panel in widget.playerSidePanels)
        if (panel.isSupportedOn(platform, PlayerMediaMode.video)) panel,
    ]..sort((a, b) => a.order.compareTo(b.order));
    return matched;
  }

  @override
  void initState() {
    super.initState();
    _prefsStream = widget.controller.env.preferencesStore.watch();
    if (widget.initialContributionId != null &&
        widget.initialContributionId!.isNotEmpty) {
      _selectedKey = '$_contribPrefix${widget.initialContributionId}';
    } else {
      _selectedKey = widget.initialTab.name;
    }
  }

  @override
  void didUpdateWidget(covariant VideoSideSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _prefsStream = widget.controller.env.preferencesStore.watch();
    }
    if (oldWidget.initialTab != widget.initialTab &&
        widget.initialContributionId == null) {
      _selectedKey = widget.initialTab.name;
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final panels = _supportedPanels;
    final mq = MediaQuery.of(context);
    final isShortLandscape =
        mq.size.height < KonataAdaptiveTokens.shortViewportHeight;
    final isTouch = widget.controller.env.platform != KonataPlatform.windows;
    // 确保右滑侧栏在任意三端横屏视口（含矮屏手机横屏）下均稳定停留在 52px 播控胶囊上方呼吸间距处。
    final capsuleBottomMargin = isTouch
        ? math.max(mq.padding.bottom, 14.0)
        : KonataPlaybackTokens.capsuleBottomOffset;
    final desiredBottomInset =
        capsuleBottomMargin + VideoPlaybackCapsule.capsuleHeight + 14.0;
    final effectiveMq =
        isShortLandscape && mq.padding.bottom + 8.0 < desiredBottomInset
        ? mq.copyWith(
            padding: mq.padding.copyWith(bottom: desiredBottomInset - 8.0),
          )
        : mq;

    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final state = widget.controller.state;
        final prefs = widget.controller.env.preferencesStore.read();

        return MediaQuery(
          data: effectiveMq,
          child: KonataGlassSideSheet(
            key: const ValueKey('video_side_sheet'),
            title: '播放控制台',
            width: KonataPlaybackTokens.videoSideSheetWidth,
            bottomInset: desiredBottomInset,
            onClose: widget.onClose,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: MediaQuery.withClampedTextScaling(
                    maxScaleFactor: 1.15,
                    child: KonataSegmentedCapsule<String>(
                      expand: true,
                      compact: true,
                      selected: _selectedKey,
                      options: [
                        for (final tab in VideoSideSheetTab.values)
                          KonataSegmentOption(
                            value: tab.name,
                            label: tab.label,
                          ),
                      ],
                      onChanged: (key) => setState(() => _selectedKey = key),
                    ),
                  ),
                ),
                if (panels.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final panel in panels)
                            Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: _SheetTabButton(
                                key: ValueKey(
                                  'side_sheet_tab_contrib_${panel.id}',
                                ),
                                label: panel.label,
                                icon: KonataIconRegistry.resolve(panel.iconKey),
                                selected:
                                    _selectedKey ==
                                    '$_contribPrefix${panel.id}',
                                onTap: () => setState(
                                  () => _selectedKey =
                                      '$_contribPrefix${panel.id}',
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
                    child: StreamBuilder<VideoPlaybackPreferences>(
                      stream: _prefsStream,
                      initialData: prefs,
                      builder: (context, snapshot) => _buildSelectedBody(
                        context,
                        p,
                        state,
                        snapshot.data ?? prefs,
                        panels,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSelectedBody(
    BuildContext context,
    KonataPalette p,
    VideoPlaybackState state,
    VideoPlaybackPreferences prefs,
    List<PlayerSidePanelContribution> panels,
  ) {
    if (_selectedKey.startsWith(_contribPrefix)) {
      final targetId = _selectedKey.substring(_contribPrefix.length);
      for (final panel in panels) {
        if (panel.id == targetId) {
          final built = panel.viewBuilder(
            ViewSlotContext(
              platformContext: context,
              workId: state.currentWork?.id,
              episodeId: state.currentEpisode.id,
              variantId: state.currentVariant.id,
              arguments: <String, Object?>{
                'mediaMode': PlayerMediaMode.video.name,
                'controller': widget.controller,
              },
            ),
          );
          return KeyedSubtree(
            key: ValueKey('side_sheet_contrib_body_${panel.id}'),
            child: built is Widget ? built : const SizedBox.shrink(),
          );
        }
      }
    }

    switch (_selectedKey) {
      case 'episodes':
        return _EpisodesSection(controller: widget.controller, state: state);
      case 'chapters':
        return _ChaptersSection(controller: widget.controller, state: state);
      case 'subtitles':
        return _SubtitlesSection(
          controller: widget.controller,
          state: state,
          prefs: prefs,
        );
      case 'audio':
        return _AudioSection(
          controller: widget.controller,
          state: state,
          prefs: prefs,
        );
      case 'video':
      default:
        return _VideoAndShadersSection(
          controller: widget.controller,
          state: state,
          activeShaderPaths: prefs.qualityConfig.activeShaderPaths,
          quality: prefs.qualityConfig,
        );
    }
  }
}

class _SheetTabButton extends StatelessWidget {
  const _SheetTabButton({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: KonataTheme.motionFast,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected
              ? p.accent.withValues(alpha: 0.22)
              : p.softFill.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected ? p.accent.withValues(alpha: 0.65) : p.hairline,
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(
                icon,
                size: 14,
                color: selected ? p.textPrimary : p.textSecondary,
              ),
              const SizedBox(width: 5),
            ],
            Text(
              label,
              style: TextStyle(
                color: selected ? p.textPrimary : p.textSecondary,
                fontSize: 12.5,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
