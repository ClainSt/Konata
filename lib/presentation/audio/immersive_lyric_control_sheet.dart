import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../application/playback/audio_playback_notifier.dart';
import '../../application/playback/playback_preferences_provider.dart';
import '../../domain/lyrics/lyric_candidate.dart';
import '../../domain/lyrics/lyric_offset_resolver.dart';
import '../../domain/playback/playback_formatters.dart';
import '../theme/konata_adaptive_tokens.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_playback_tokens.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/ellipsis_text_with_tooltip.dart';
import '../widgets/design_system/konata_draggable_scrollbar.dart';
import '../widgets/design_system/konata_glass_side_sheet.dart';
import '../widgets/design_system/konata_pill_button.dart';
import '../widgets/design_system/konata_segmented_capsule.dart';
import '../widgets/design_system/konata_soft_text_field.dart';
import '../widgets/design_system/konata_surface_card.dart';
import '../widgets/design_system/konata_switch.dart';
import '../widgets/design_system/konata_toast.dart';
import '../widgets/playback/konata_spec_badge.dart';

enum _LyricControlTab { candidates, offsets }

/// 全端统一沉浸歌词控制侧栏：换候选、手动重搜、恢复自动与单曲/专辑/路由三级偏移实时校准。
///
/// 复用全站 `KonataGlassSideSheet`、`KonataSegmentedCapsule`、`KonataSoftTextField`、
/// `KonataPillButton`、`KonataDraggableScrollbar` 与 `showKonataToast`，桌面/平板/手机双方向同源自适应。
class ImmersiveLyricControlSheet extends ConsumerStatefulWidget {
  /// 创建歌词控制侧栏。
  const ImmersiveLyricControlSheet({super.key, required this.onClose});

  /// 关闭侧栏回调。
  final VoidCallback onClose;

  @override
  ConsumerState<ImmersiveLyricControlSheet> createState() =>
      _ImmersiveLyricControlSheetState();
}

class _ImmersiveLyricControlSheetState
    extends ConsumerState<ImmersiveLyricControlSheet> {
  final ScrollController _scrollCtrl = ScrollController();
  late final TextEditingController _titleCtrl;
  late final TextEditingController _artistCtrl;
  _LyricControlTab _activeTab = _LyricControlTab.candidates;
  bool _searching = false;
  bool _hasManualSearched = false;
  String? _boundItemId;

  @override
  void initState() {
    super.initState();
    final item = ref.read(audioPlaybackProvider).currentItem;
    _boundItemId = item?.id;
    _titleCtrl = TextEditingController(text: item?.title ?? '');
    _artistCtrl = TextEditingController(text: item?.performer ?? '');
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    _titleCtrl.dispose();
    _artistCtrl.dispose();
    super.dispose();
  }

  Future<void> _runManualSearch() async {
    if (_searching) return;
    setState(() => _searching = true);
    try {
      final results = await ref
          .read(audioPlaybackProvider.notifier)
          .searchLyricCandidatesManual(
            title: _titleCtrl.text,
            artist: _artistCtrl.text,
          );
      if (!mounted) return;
      setState(() => _hasManualSearched = true);
      if (results.isEmpty) {
        showKonataToast(context, '未检索到匹配歌词候选，请尝试精简曲名');
      }
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _pickCandidate(ScoredLyricCandidate candidate) async {
    final ok = await ref
        .read(audioPlaybackProvider.notifier)
        .selectLyricCandidate(candidate);
    if (!mounted) return;
    showKonataToast(context, ok ? '已切换并锁定歌词' : '该候选歌词正文无效，无法切换');
  }

  Future<void> _unlockAutoMatch() async {
    await ref.read(audioPlaybackProvider.notifier).resetToAutoLyricMatch();
    if (!mounted) return;
    showKonataToast(context, '已恢复自动歌词匹配');
  }

  Future<void> _promoteOffsetToAlbum() async {
    await ref.read(audioPlaybackProvider.notifier).promoteCurrentOffsetToAlbum();
    if (!mounted) return;
    showKonataToast(context, '已将当前偏移应用至整张专辑');
  }

  static String _sourceLabel(LyricSource? source) {
    return switch (source) {
      LyricSource.local => '本地外挂 / 内嵌',
      LyricSource.amll => 'AMLL 逐字',
      LyricSource.netease => '网易云音乐',
      LyricSource.qq => 'QQ 音乐',
      LyricSource.lrclib => 'LRCLIB',
      null => '暂无同步歌词',
    };
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = ref.watch(
      audioPlaybackProvider.select(
        (s) => (
          item: s.currentItem,
          source: s.activeLyricSource,
          sourceId: s.activeLyricSourceId,
          hasLrc: s.lrcDocument != null && s.lrcDocument!.lines.isNotEmpty,
          userEdited: s.isLyricUserEdited,
          offset: s.lyricOffset,
          candidates: s.lyricCandidates,
        ),
      ),
    );
    final prefs = ref.watch(
      playbackPreferencesProvider.select(
        (s) => (
          showRomaji: s.showLyricRomaji,
          wiredOffsetMs: s.lyricWiredOffsetMillis,
          btOffsetMs: s.lyricBluetoothOffsetMillis,
        ),
      ),
    );

    if (state.item != null && state.item!.id != _boundItemId) {
      _boundItemId = state.item!.id;
      _titleCtrl.text = state.item!.title;
      _artistCtrl.text = state.item!.performer;
      _hasManualSearched = false;
    }

    final notifier = ref.read(audioPlaybackProvider.notifier);
    final prefsNotifier = ref.read(playbackPreferencesProvider.notifier);

    return KonataGlassSideSheet(
      key: const ValueKey('immersive_lyric_control_sheet'),
      title: '歌词换源与校准',
      width: 440,
      onClose: widget.onClose,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
            child: KonataSegmentedCapsule<_LyricControlTab>(
              key: const ValueKey('lyric_control_tab_capsule'),
              selected: _activeTab,
              expand: true,
              onChanged: (tab) => setState(() => _activeTab = tab),
              options: const [
                KonataSegmentOption(
                  value: _LyricControlTab.candidates,
                  label: '换候选与重搜',
                  icon: Icons.manage_search_rounded,
                ),
                KonataSegmentOption(
                  value: _LyricControlTab.offsets,
                  label: '三级时间轴校准',
                  icon: Icons.tune_rounded,
                ),
              ],
            ),
          ),
          Expanded(
            child: KonataDraggableScrollbar(
              controller: _scrollCtrl,
              trackInsets: const EdgeInsets.only(right: 4, bottom: 10),
              builder: (_, ctrl) => ListView(
                controller: ctrl,
                padding: const EdgeInsets.fromLTRB(18, 0, 20, 20),
                children: _activeTab == _LyricControlTab.candidates
                    ? _buildCandidatesTab(
                        p: p,
                        source: state.source,
                        sourceId: state.sourceId,
                        userEdited: state.userEdited,
                        candidates: state.candidates,
                        showRomaji: prefs.showRomaji,
                        prefsNotifier: prefsNotifier,
                      )
                    : _buildOffsetsTab(
                        p: p,
                        albumTitle: state.item?.albumTitle ?? '',
                        offset: state.offset,
                        wiredOffsetMs: prefs.wiredOffsetMs,
                        btOffsetMs: prefs.btOffsetMs,
                        notifier: notifier,
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildCandidatesTab({
    required KonataPalette p,
    required LyricSource? source,
    required String sourceId,
    required bool userEdited,
    required List<ScoredLyricCandidate> candidates,
    required bool showRomaji,
    required PlaybackPreferencesNotifier prefsNotifier,
  }) {
    return [
      KonataSurfaceCard(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '当前生效：${_sourceLabel(source)}',
                        style: TextStyle(
                          color: p.textPrimary,
                          fontSize: KonataTheme.fontSizeBodySm,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        userEdited
                            ? '已手动锁定，自动检索与版本升级不会覆盖'
                            : '自动多源竞速匹配中，支持手动切换或重新检索',
                        style: KonataTheme.captionStyle(p),
                      ),
                    ],
                  ),
                ),
                if (userEdited) ...[
                  const SizedBox(width: 8),
                  KonataPillButton.secondary(
                    key: const ValueKey('lyric_unlock_auto_button'),
                    label: '恢复自动',
                    compact: true,
                    onPressed: () => unawaited(_unlockAutoMatch()),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 10),
            Divider(height: 1, color: p.hairline),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '显示罗马音注音',
                    style: TextStyle(
                      color: p.textSecondary,
                      fontSize: KonataTheme.fontSizeBodySm,
                    ),
                  ),
                ),
                KonataSwitch(
                  key: const ValueKey('lyric_control_romaji_switch'),
                  value: showRomaji,
                  onChanged: (v) =>
                      unawaited(prefsNotifier.setShowLyricRomaji(v)),
                ),
              ],
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      KonataSurfaceCard(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '手动重搜在线歌词',
              style: TextStyle(
                color: p.textPrimary,
                fontSize: KonataTheme.fontSizeBodySm,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            KonataSoftTextField(
              key: const ValueKey('lyric_manual_title_field'),
              controller: _titleCtrl,
              label: '曲名关键词',
              hintText: '输入原名、日文名或译名',
              dense: true,
              onSubmitted: (_) => unawaited(_runManualSearch()),
            ),
            const SizedBox(height: 10),
            KonataSoftTextField(
              key: const ValueKey('lyric_manual_artist_field'),
              controller: _artistCtrl,
              label: '歌手（可选）',
              hintText: '留空可扩大检索范围',
              dense: true,
              onSubmitted: (_) => unawaited(_runManualSearch()),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: KonataPillButton.primary(
                key: const ValueKey('lyric_manual_search_button'),
                label: _searching ? '正在检索…' : '搜索候选',
                icon: Icons.search_rounded,
                compact: true,
                onPressed: _searching ? null : () => unawaited(_runManualSearch()),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 14),
      Padding(
        padding: const EdgeInsets.only(left: 2, bottom: 8),
        child: Text(
          candidates.isEmpty ? '候选列表' : '可选候选（共 ${candidates.length} 条）',
          style: TextStyle(
            color: p.textSecondary,
            fontSize: KonataTheme.fontSizeCaption,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      if (candidates.isEmpty)
        KonataSurfaceCard(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 18),
          child: Text(
            _hasManualSearched
                ? '未找到可用的同步歌词，请修改关键词后重试。'
                : '当前尚未缓存其他候选，点击上方「搜索候选」即可枚举全部已启用来源结果。',
            style: KonataTheme.captionStyle(p),
          ),
        )
      else
        for (var i = 0; i < candidates.length; i++) ...[
          _buildCandidateTile(
            p: p,
            index: i,
            scored: candidates[i],
            isSelected:
                candidates[i].candidate.source == source &&
                candidates[i].candidate.sourceId == sourceId,
          ),
          if (i + 1 < candidates.length) const SizedBox(height: 8),
        ],
    ];
  }

  Widget _buildCandidateTile({
    required KonataPalette p,
    required int index,
    required ScoredLyricCandidate scored,
    required bool isSelected,
  }) {
    final c = scored.candidate;
    final durText = c.durationSeconds != null && c.durationSeconds! > 0
        ? PlaybackFormatters.formatMediaDuration(c.durationSeconds!)
        : '';
    final subParts = <String>[
      if (c.artist.trim().isNotEmpty) c.artist.trim(),
      if (durText.isNotEmpty) durText,
    ];
    final minH = KonataAdaptiveTokens.isAndroid
        ? KonataAdaptiveTokens.touchTarget
        : 0.0;

    return GestureDetector(
      key: ValueKey('lyric_candidate_item_$index'),
      behavior: HitTestBehavior.opaque,
      onTap: () => unawaited(_pickCandidate(scored)),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: minH),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            color: isSelected
                ? KonataPlaybackTokens.activePillBg(p)
                : p.softFill,
            borderRadius: KonataTheme.borderRadiusControl,
            border: Border.all(
              color: isSelected ? p.hoverBorder : p.hairline,
              width: 1,
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    EllipsisTextWithTooltip(
                      text: c.title,
                      style: TextStyle(
                        color: p.textPrimary,
                        fontSize: KonataTheme.fontSizeBodySm,
                        fontWeight: isSelected
                            ? FontWeight.w700
                            : FontWeight.w600,
                      ),
                    ),
                    if (subParts.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        subParts.join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: KonataTheme.captionStyle(p),
                      ),
                    ],
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        KonataSpecBadge(label: _sourceLabel(c.source)),
                        if (c.hasWordTiming) const KonataSpecBadge(label: '逐字'),
                        if (c.hasTranslation) const KonataSpecBadge(label: '译文'),
                        if (c.hasRomaji) const KonataSpecBadge(label: '罗马音'),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Icon(
                isSelected
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 20,
                color: isSelected ? p.progressFill : p.textMuted,
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildOffsetsTab({
    required KonataPalette p,
    required String albumTitle,
    required LyricOffsetSnapshot offset,
    required int wiredOffsetMs,
    required int btOffsetMs,
    required AudioPlaybackNotifier notifier,
  }) {
    final totalLabel = LyricOffsetResolver.formatOffsetSeconds(
      offset.totalOffsetMillis,
    );
    final trackLabel = LyricOffsetResolver.formatOffsetSeconds(
      offset.trackOffsetMillis,
    );
    final albumLabel = LyricOffsetResolver.formatOffsetSeconds(
      offset.albumOffsetMillis,
    );
    final routeLabel = LyricOffsetResolver.formatOffsetSeconds(
      offset.routeOffsetMillis,
    );

    return [
      KonataSurfaceCard(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '当前生效总偏移',
                  style: TextStyle(
                    color: p.textSecondary,
                    fontSize: KonataTheme.fontSizeBodySm,
                  ),
                ),
                const Spacer(),
                Text(
                  totalLabel,
                  key: const ValueKey('lyric_total_offset_value'),
                  style: TextStyle(
                    color: p.textPrimary,
                    fontSize: KonataTheme.fontSizeH2,
                    fontWeight: FontWeight.w700,
                    fontFeatures: KonataPlaybackTokens.tabularNumbers,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '正值歌词提前 · 负值歌词延后（单曲 $trackLabel + 专辑 $albumLabel + ${offset.activeRouteKind.label} $routeLabel）',
              style: KonataTheme.captionStyle(p),
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      _buildOffsetCard(
        p: p,
        title: '单曲偏移',
        subtitle: '仅作用于当前曲目并永久锁定，不被自动检索覆盖',
        valueKey: const ValueKey('lyric_track_offset_value'),
        valueLabel: trackLabel,
        stepButtons: [
          _OffsetStepSpec(
            key: const ValueKey('lyric_track_offset_minus_500'),
            label: '-0.5s',
            onTap: () => unawaited(notifier.adjustTrackLyricOffsetMillis(-500)),
          ),
          _OffsetStepSpec(
            key: const ValueKey('lyric_track_offset_minus_100'),
            label: '-0.1s',
            onTap: () => unawaited(notifier.adjustTrackLyricOffsetMillis(-100)),
          ),
          _OffsetStepSpec(
            key: const ValueKey('lyric_track_offset_reset'),
            label: '归零',
            onTap: () => unawaited(
              notifier.setTrackLyricOffsetMillis(0, userOffsetLocked: false),
            ),
          ),
          _OffsetStepSpec(
            key: const ValueKey('lyric_track_offset_plus_100'),
            label: '+0.1s',
            onTap: () => unawaited(notifier.adjustTrackLyricOffsetMillis(100)),
          ),
          _OffsetStepSpec(
            key: const ValueKey('lyric_track_offset_plus_500'),
            label: '+0.5s',
            onTap: () => unawaited(notifier.adjustTrackLyricOffsetMillis(500)),
          ),
        ],
        footerAction: offset.trackOffsetMillis == 0
            ? null
            : Align(
                alignment: Alignment.centerRight,
                child: KonataPillButton.secondary(
                  key: const ValueKey('lyric_apply_to_album_button'),
                  label: '一键应用到整张专辑',
                  icon: Icons.album_outlined,
                  compact: true,
                  onPressed: () => unawaited(_promoteOffsetToAlbum()),
                ),
              ),
      ),
      const SizedBox(height: 12),
      _buildOffsetCard(
        p: p,
        title: '专辑级偏移',
        subtitle: albumTitle.trim().isNotEmpty
            ? '作用于「${albumTitle.trim()}」全部曲目'
            : '作用于当前专辑目录内全部曲目',
        valueKey: const ValueKey('lyric_album_offset_value'),
        valueLabel: albumLabel,
        stepButtons: [
          _OffsetStepSpec(
            key: const ValueKey('lyric_album_offset_minus_500'),
            label: '-0.5s',
            onTap: () => unawaited(
              notifier.setAlbumLyricOffsetMillis(offset.albumOffsetMillis - 500),
            ),
          ),
          _OffsetStepSpec(
            key: const ValueKey('lyric_album_offset_minus_100'),
            label: '-0.1s',
            onTap: () => unawaited(
              notifier.setAlbumLyricOffsetMillis(offset.albumOffsetMillis - 100),
            ),
          ),
          _OffsetStepSpec(
            key: const ValueKey('lyric_album_offset_reset'),
            label: '归零',
            onTap: () => unawaited(notifier.setAlbumLyricOffsetMillis(0)),
          ),
          _OffsetStepSpec(
            key: const ValueKey('lyric_album_offset_plus_100'),
            label: '+0.1s',
            onTap: () => unawaited(
              notifier.setAlbumLyricOffsetMillis(offset.albumOffsetMillis + 100),
            ),
          ),
          _OffsetStepSpec(
            key: const ValueKey('lyric_album_offset_plus_500'),
            label: '+0.5s',
            onTap: () => unawaited(
              notifier.setAlbumLyricOffsetMillis(offset.albumOffsetMillis + 500),
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      KonataSurfaceCard(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '输出路由全局延迟',
              style: TextStyle(
                color: p.textPrimary,
                fontSize: KonataTheme.fontSizeBodySm,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '当前活跃路由：${offset.activeRouteKind.label}（有线与蓝牙独立保存，切换耳机自动生效）',
              style: KonataTheme.captionStyle(p),
            ),
            const SizedBox(height: 12),
            _buildRouteDelayRow(
              p: p,
              kind: LyricAudioRouteKind.wired,
              active: offset.activeRouteKind == LyricAudioRouteKind.wired,
              millis: wiredOffsetMs,
              keyPrefix: 'lyric_route_wired',
              notifier: notifier,
            ),
            const SizedBox(height: 10),
            Divider(height: 1, color: p.hairline),
            const SizedBox(height: 10),
            _buildRouteDelayRow(
              p: p,
              kind: LyricAudioRouteKind.bluetooth,
              active: offset.activeRouteKind == LyricAudioRouteKind.bluetooth,
              millis: btOffsetMs,
              keyPrefix: 'lyric_route_bluetooth',
              notifier: notifier,
            ),
          ],
        ),
      ),
    ];
  }

  Widget _buildOffsetCard({
    required KonataPalette p,
    required String title,
    required String subtitle,
    required Key valueKey,
    required String valueLabel,
    required List<_OffsetStepSpec> stepButtons,
    Widget? footerAction,
  }) {
    return KonataSurfaceCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                title,
                style: TextStyle(
                  color: p.textPrimary,
                  fontSize: KonataTheme.fontSizeBodySm,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Text(
                valueLabel,
                key: valueKey,
                style: TextStyle(
                  color: p.textPrimary,
                  fontSize: KonataTheme.fontSizeBody,
                  fontWeight: FontWeight.w700,
                  fontFeatures: KonataPlaybackTokens.tabularNumbers,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(subtitle, style: KonataTheme.captionStyle(p)),
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final step in stepButtons)
                KonataPillButton.secondary(
                  key: step.key,
                  label: step.label,
                  compact: true,
                  onPressed: step.onTap,
                ),
            ],
          ),
          if (footerAction != null) ...[
            const SizedBox(height: 10),
            footerAction,
          ],
        ],
      ),
    );
  }

  Widget _buildRouteDelayRow({
    required KonataPalette p,
    required LyricAudioRouteKind kind,
    required bool active,
    required int millis,
    required String keyPrefix,
    required AudioPlaybackNotifier notifier,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              kind.label,
              style: TextStyle(
                color: p.textPrimary,
                fontSize: KonataTheme.fontSizeBodySm,
                fontWeight: active ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
            if (active) ...[
              const SizedBox(width: 6),
              const KonataSpecBadge(label: '当前'),
            ],
            const Spacer(),
            Text(
              LyricOffsetResolver.formatOffsetSeconds(millis),
              key: ValueKey('${keyPrefix}_value'),
              style: TextStyle(
                color: p.textPrimary,
                fontSize: KonataTheme.fontSizeBodySm,
                fontWeight: FontWeight.w600,
                fontFeatures: KonataPlaybackTokens.tabularNumbers,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            KonataPillButton.secondary(
              key: ValueKey('${keyPrefix}_minus_100'),
              label: '-0.1s',
              compact: true,
              onPressed: () => unawaited(
                notifier.setRouteLyricOffsetMillis(kind, millis - 100),
              ),
            ),
            KonataPillButton.secondary(
              key: ValueKey('${keyPrefix}_reset'),
              label: '归零',
              compact: true,
              onPressed: () =>
                  unawaited(notifier.setRouteLyricOffsetMillis(kind, 0)),
            ),
            KonataPillButton.secondary(
              key: ValueKey('${keyPrefix}_plus_100'),
              label: '+0.1s',
              compact: true,
              onPressed: () => unawaited(
                notifier.setRouteLyricOffsetMillis(kind, millis + 100),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _OffsetStepSpec {
  const _OffsetStepSpec({
    required this.key,
    required this.label,
    required this.onTap,
  });

  final Key key;
  final String label;
  final VoidCallback onTap;
}
