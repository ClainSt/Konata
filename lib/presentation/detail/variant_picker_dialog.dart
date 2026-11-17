import 'package:flutter/material.dart';

import '../../application/playback/playback_preferences_provider.dart';
import '../../domain/formatting/media_display_formatter.dart';
import '../../domain/matching/episode_title_formatter.dart';
import '../../domain/models/episode.dart';
import '../../domain/models/external_player_config.dart';
import '../../domain/models/media_source.dart';
import '../../domain/models/media_variant.dart';
import '../theme/konata_adaptive_tokens.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/konata_draggable_scrollbar.dart';
import '../widgets/design_system/konata_dropdown.dart';
import '../widgets/design_system/konata_glass_dialog.dart';
import '../widgets/design_system/konata_surface_card.dart';

/// 多版本选播毛玻璃弹窗（无粗框柔和胶囊徽章 + 亮/暗双主题语义适配 + 内外播放器直选）。
class VariantPickerDialog extends StatefulWidget {
  /// 创建多版本选播弹窗。
  const VariantPickerDialog({
    super.key,
    required this.episode,
    required this.variants,
    required this.sourcesById,
    required this.players,
    required this.onPlay,
    this.initialEngine,
    this.initialPlayer,
  });

  /// 目标剧集。
  final Episode episode;

  /// 可选物理版本列表。
  final List<MediaVariant> variants;

  /// 媒体源字典。
  final Map<String, MediaSource> sourcesById;

  /// 已配置的外部播放器列表。
  final List<ExternalPlayerConfig> players;

  /// 预设引擎（空则默认跟随全局设置）。
  final PreferredPlaybackEngine? initialEngine;

  /// 预设外部播放器。
  final ExternalPlayerConfig? initialPlayer;

  /// 确认播放回调。
  final void Function(
    MediaVariant variant,
    PreferredPlaybackEngine? engineOverride,
    ExternalPlayerConfig? player,
  )
  onPlay;

  @override
  State<VariantPickerDialog> createState() => _VariantPickerDialogState();
}

class _VariantPickerDialogState extends State<VariantPickerDialog> {
  static const String _optionFollowDefault = '__follow_default__';
  static const String _optionBuiltin = '__builtin_libmpv__';

  final ScrollController _listCtrl = ScrollController();
  late String _selectedTargetId;

  @override
  void initState() {
    super.initState();
    if (widget.initialPlayer != null) {
      _selectedTargetId = widget.initialPlayer!.id;
    } else if (widget.initialEngine == PreferredPlaybackEngine.builtinLibmpv) {
      _selectedTargetId = _optionBuiltin;
    } else if (widget.initialEngine == PreferredPlaybackEngine.externalPlayer &&
        widget.players.isNotEmpty) {
      final def = widget.players.firstWhere(
        (p) => p.isDefault,
        orElse: () => widget.players.first,
      );
      _selectedTargetId = def.id;
    } else {
      _selectedTargetId = _optionFollowDefault;
    }
  }

  (PreferredPlaybackEngine?, ExternalPlayerConfig?) _resolveSelection() {
    if (_selectedTargetId == _optionFollowDefault) {
      return (null, null);
    }
    if (_selectedTargetId == _optionBuiltin) {
      return (PreferredPlaybackEngine.builtinLibmpv, null);
    }
    for (final pl in widget.players) {
      if (pl.id == _selectedTargetId) {
        return (PreferredPlaybackEngine.externalPlayer, pl);
      }
    }
    return (null, null);
  }

  @override
  void dispose() {
    _listCtrl.dispose();
    super.dispose();
  }

  String _sourceLabel(MediaSourceKind? kind) {
    switch (kind) {
      case MediaSourceKind.webdav:
        return 'WebDAV';
      case MediaSourceKind.smb:
        return 'SMB';
      case MediaSourceKind.local:
      case null:
        return '本地磁盘';
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final epLabel = EpisodeTitleFormatter.formatCardTitle(
      episode: widget.episode,
    );

    return KonataGlassDialog(
      width: 660,
      maxHeight: 540,
      title: '选择播放版本 · $epLabel',
      headerTrailing: KonataAdaptiveTokens.isWindows
          ? SizedBox(
              width: 196,
              child: KonataDropdown<String>(
                dense: true,
                leadingIcon: Icons.play_circle_outline_rounded,
                value: _selectedTargetId,
                options: [
                  const KonataDropdownOption<String>(
                    value: _optionFollowDefault,
                    label: '跟随全局播放设置',
                  ),
                  const KonataDropdownOption<String>(
                    value: _optionBuiltin,
                    label: '内置高保真 (libmpv)',
                  ),
                  for (final pl in widget.players)
                    KonataDropdownOption<String>(
                      value: pl.id,
                      label: '外部 · ${pl.name}',
                    ),
                ],
                onChanged: (id) {
                  setState(() {
                    _selectedTargetId = id;
                  });
                },
              ),
            )
          : null,
      child: KonataDraggableScrollbar(
        controller: _listCtrl,
        builder: (_, ctrl) => ListView.separated(
          controller: ctrl,
          padding: const EdgeInsets.only(right: 14),
          shrinkWrap: true,
          itemCount: widget.variants.length,
          separatorBuilder: (_, _) => const SizedBox(height: 10),
          itemBuilder: (_, index) {
          final v = widget.variants[index];
          final sourceKind = widget.sourcesById[v.sourceId]?.kind;
          final videoSpec = [
            if (v.videoCodec != null) v.videoCodec!,
            if (v.bitDepth != null) v.bitDepth!,
            if (v.resolution != null) v.resolution!,
          ].join(' · ');
          final subText = v.externalSubtitles.isNotEmpty
              ? '${v.subtitleGroup ?? '外挂字幕'} (${v.externalSubtitles.length})'
              : (v.subtitleGroup ?? '');

          return GestureDetector(
            onTap: () {
              final selection = _resolveSelection();
              Navigator.of(context).pop();
              widget.onPlay(v, selection.$1, selection.$2);
            },
            child: KonataSurfaceCard(
              padding: const EdgeInsets.all(14),
              enableHover: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      if (v.releaseGroup != null &&
                          v.releaseGroup!.isNotEmpty)
                        _ColorPill(
                          label: '压制: ${v.releaseGroup!}',
                          color: KonataTheme.specReleaseBlue,
                        ),
                      if (subText.isNotEmpty)
                        _ColorPill(
                          label: '字幕: $subText',
                          color: KonataTheme.specSubtitleGreen,
                        ),
                      if (videoSpec.isNotEmpty)
                        _ColorPill(
                          label: videoSpec,
                          color: KonataTheme.specVideoPurple,
                        ),
                      if (v.audioCodec != null &&
                          v.audioCodec!.isNotEmpty)
                        _ColorPill(
                          label: '音频: ${v.audioCodec!}',
                          color: KonataTheme.specAudioAmber,
                        ),
                      _ColorPill(
                        label: _sourceLabel(sourceKind),
                        color: p.accent,
                      ),
                      if (v.fileSize > 0)
                        _ColorPill(
                          label: MediaDisplayFormatter.formatBytes(v.fileSize),
                          color: p.textSecondary,
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    v.fileName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'Consolas',
                      color: p.textSecondary,
                      fontSize: 11.5,
                    ),
                  ),
                  if (v.relativePath.isNotEmpty &&
                      v.relativePath != v.fileName) ...[
                    const SizedBox(height: 3),
                    Text(
                      v.relativePath,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'Consolas',
                        color: p.textMuted,
                        fontSize: 10.5,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
      ),
    );
  }
}

class _ColorPill extends StatelessWidget {
  const _ColorPill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
