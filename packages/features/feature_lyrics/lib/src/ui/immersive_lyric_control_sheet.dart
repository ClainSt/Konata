import 'dart:async';

import 'package:engine_playback/engine_playback.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../domain/lyric_candidate.dart';
import '../domain/lyric_offset_resolver.dart';
import '../state/lyric_display_controller.dart';

enum _LyricControlTab { candidates, offsets }

/// 全端统一沉浸歌词控制侧栏：换候选、手动重搜、恢复自动、双语/罗马音开关与单曲/专辑/输出路由三级偏移实时校准。
class ImmersiveLyricControlSheet extends StatefulWidget {
  /// 创建歌词控制侧栏。
  const ImmersiveLyricControlSheet({
    super.key,
    required this.controller,
    required this.onClose,
    this.embedded = false,
  });

  /// 歌词展示与控制状态协调器。
  final LyricDisplayController controller;

  /// 关闭侧栏回调。
  final VoidCallback onClose;

  /// 是否内嵌在右上角统一菜单面板中（内嵌时不套外层侧栏壳并使用自适应高度）。
  final bool embedded;

  @override
  State<ImmersiveLyricControlSheet> createState() =>
      _ImmersiveLyricControlSheetState();
}

class _ImmersiveLyricControlSheetState
    extends State<ImmersiveLyricControlSheet> {
  final ScrollController _scrollCtrl = ScrollController();
  late final TextEditingController _titleCtrl;
  late final TextEditingController _artistCtrl;
  _LyricControlTab _activeTab = _LyricControlTab.candidates;
  bool _searching = false;
  bool _hasManualSearched = false;
  String? _boundTrackKey;

  @override
  void initState() {
    super.initState();
    final query = widget.controller.state.activeQuery;
    _boundTrackKey = query?.trackKey;
    _titleCtrl = TextEditingController(text: query?.title ?? '');
    _artistCtrl = TextEditingController(text: query?.artist ?? '');
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
      final results = await widget.controller.searchCandidatesManual(
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
    final ok = await widget.controller.selectCandidate(candidate);
    if (!mounted) return;
    showKonataToast(context, ok ? '已切换并锁定歌词' : '该候选歌词正文无效，无法切换');
  }

  Future<void> _unlockAutoMatch() async {
    await widget.controller.resetToAutoMatch();
    if (!mounted) return;
    showKonataToast(context, '已恢复自动歌词匹配');
  }

  Future<void> _promoteOffsetToAlbum() async {
    await widget.controller.promoteCurrentOffsetToAlbum();
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
    return Theme(
      data: KonataTheme.darkTheme(),
      child: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          const p = KonataPalette.dark;
          final state = widget.controller.state;
          final prefs = widget.controller.preferences;
          final query = state.activeQuery;

          if (query != null && query.trackKey != _boundTrackKey) {
            _boundTrackKey = query.trackKey;
            _titleCtrl.text = query.title;
            _artistCtrl.text = query.artist;
            _hasManualSearched = false;
          }

          final tabCapsule = KonataSegmentedCapsule<_LyricControlTab>(
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
          );

          final activeTabChildren = _activeTab == _LyricControlTab.candidates
              ? _buildCandidatesTab(
                  p: p,
                  source: state.activeSource,
                  sourceId: state.activeSourceId,
                  userEdited: state.isUserEdited,
                  candidates: state.candidates,
                  showRomaji: prefs.showRomaji,
                  showTranslation: prefs.showTranslation,
                  includeDisplayTogglesInCard: !widget.embedded,
                )
              : _buildOffsetsTab(
                  p: p,
                  albumTitle: query?.album ?? '',
                  offset: state.offsetSnapshot,
                  wiredOffsetMs: prefs.wiredOffsetMillis,
                  btOffsetMs: prefs.bluetoothOffsetMillis,
                  includeQuickOffsetBar: !widget.embedded,
                );

          if (widget.embedded) {
            return Column(
              key: const ValueKey('immersive_lyric_control_sheet'),
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildQuickControlCard(
                  p: p,
                  showTranslation: prefs.showTranslation,
                  showRomaji: prefs.showRomaji,
                  offset: state.offsetSnapshot,
                ),
                const SizedBox(height: 12),
                tabCapsule,
                const SizedBox(height: 12),
                ...activeTabChildren,
              ],
            );
          }

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
                  child: tabCapsule,
                ),
                Expanded(
                  child: KonataDraggableScrollbar(
                    controller: _scrollCtrl,
                    trackInsets: const EdgeInsets.only(right: 4, bottom: 10),
                    builder: (_, ctrl) => ListView(
                      controller: ctrl,
                      padding: const EdgeInsets.fromLTRB(18, 0, 20, 20),
                      children: activeTabChildren,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildQuickControlCard({
    required KonataPalette p,
    required bool showTranslation,
    required bool showRomaji,
    required LyricOffsetSnapshot offset,
  }) {
    final totalLabel = LyricOffsetResolver.formatOffsetSeconds(
      offset.totalOffsetMillis,
    );
    return KonataSurfaceCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '显示双语译文',
                  style: TextStyle(
                    color: p.textPrimary,
                    fontSize: KonataTheme.fontSizeBodySm,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              KonataSwitch(
                key: const ValueKey('lyric_control_translation_switch'),
                value: showTranslation,
                onChanged: widget.controller.setShowTranslation,
              ),
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
                    color: p.textPrimary,
                    fontSize: KonataTheme.fontSizeBodySm,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              KonataSwitch(
                key: const ValueKey('lyric_control_romaji_switch'),
                value: showRomaji,
                onChanged: widget.controller.setShowRomaji,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Divider(height: 1, color: p.hairline),
          const SizedBox(height: 10),
          Row(
            children: [
              Text(
                '歌词延迟微调',
                style: TextStyle(
                  color: p.textPrimary,
                  fontSize: KonataTheme.fontSizeBodySm,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const Spacer(),
              Text(
                totalLabel,
                key: const ValueKey('lyric_quick_offset_value'),
                style: TextStyle(
                  color: p.textSecondary,
                  fontSize: KonataTheme.fontSizeCaption,
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
                key: const ValueKey('lyric_quick_offset_minus_200'),
                label: '-0.2s',
                compact: true,
                onPressed: () =>
                    unawaited(widget.controller.adjustTrackOffsetMillis(-200)),
              ),
              KonataPillButton.secondary(
                key: const ValueKey('lyric_quick_offset_reset'),
                label: '归零',
                compact: true,
                onPressed: () => unawaited(
                  widget.controller.setTrackOffsetMillis(
                    0,
                    userOffsetLocked: false,
                  ),
                ),
              ),
              KonataPillButton.secondary(
                key: const ValueKey('lyric_quick_offset_plus_200'),
                label: '+0.2s',
                compact: true,
                onPressed: () =>
                    unawaited(widget.controller.adjustTrackOffsetMillis(200)),
              ),
            ],
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
    required bool showTranslation,
    required bool includeDisplayTogglesInCard,
  }) {
    return [
      KonataSurfaceCard(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
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
            if (includeDisplayTogglesInCard) ...[
              const SizedBox(height: 8),
              Divider(height: 1, color: p.hairline),
              const SizedBox(height: 8),
              Wrap(
                spacing: 14,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '双语译文',
                        style: TextStyle(
                          color: p.textSecondary,
                          fontSize: KonataTheme.fontSizeBodySm,
                        ),
                      ),
                      const SizedBox(width: 8),
                      KonataSwitch(
                        key: const ValueKey('lyric_control_translation_switch'),
                        value: showTranslation,
                        onChanged: widget.controller.setShowTranslation,
                      ),
                    ],
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '罗马音注音',
                        style: TextStyle(
                          color: p.textSecondary,
                          fontSize: KonataTheme.fontSizeBodySm,
                        ),
                      ),
                      const SizedBox(width: 8),
                      KonataSwitch(
                        key: const ValueKey('lyric_control_romaji_switch'),
                        value: showRomaji,
                        onChanged: widget.controller.setShowRomaji,
                      ),
                    ],
                  ),
                ],
              ),
            ],
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
    bool includeQuickOffsetBar = false,
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
            if (includeQuickOffsetBar) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  KonataPillButton.secondary(
                    key: const ValueKey('lyric_quick_offset_minus_200'),
                    label: '-0.2s',
                    compact: true,
                    onPressed: () => unawaited(
                      widget.controller.adjustTrackOffsetMillis(-200),
                    ),
                  ),
                  KonataPillButton.secondary(
                    key: const ValueKey('lyric_quick_offset_reset'),
                    label: '归零',
                    compact: true,
                    onPressed: () => unawaited(
                      widget.controller.setTrackOffsetMillis(
                        0,
                        userOffsetLocked: false,
                      ),
                    ),
                  ),
                  KonataPillButton.secondary(
                    key: const ValueKey('lyric_quick_offset_plus_200'),
                    label: '+0.2s',
                    compact: true,
                    onPressed: () => unawaited(
                      widget.controller.adjustTrackOffsetMillis(200),
                    ),
                  ),
                ],
              ),
            ],
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
            onTap: () =>
                unawaited(widget.controller.adjustTrackOffsetMillis(-500)),
          ),
          _OffsetStepSpec(
            key: const ValueKey('lyric_track_offset_minus_100'),
            label: '-0.1s',
            onTap: () =>
                unawaited(widget.controller.adjustTrackOffsetMillis(-100)),
          ),
          _OffsetStepSpec(
            key: const ValueKey('lyric_track_offset_reset'),
            label: '归零',
            onTap: () => unawaited(
              widget.controller.setTrackOffsetMillis(
                0,
                userOffsetLocked: false,
              ),
            ),
          ),
          _OffsetStepSpec(
            key: const ValueKey('lyric_track_offset_plus_100'),
            label: '+0.1s',
            onTap: () =>
                unawaited(widget.controller.adjustTrackOffsetMillis(100)),
          ),
          _OffsetStepSpec(
            key: const ValueKey('lyric_track_offset_plus_500'),
            label: '+0.5s',
            onTap: () =>
                unawaited(widget.controller.adjustTrackOffsetMillis(500)),
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
              widget.controller.setAlbumOffsetMillis(
                offset.albumOffsetMillis - 500,
              ),
            ),
          ),
          _OffsetStepSpec(
            key: const ValueKey('lyric_album_offset_minus_100'),
            label: '-0.1s',
            onTap: () => unawaited(
              widget.controller.setAlbumOffsetMillis(
                offset.albumOffsetMillis - 100,
              ),
            ),
          ),
          _OffsetStepSpec(
            key: const ValueKey('lyric_album_offset_reset'),
            label: '归零',
            onTap: () => unawaited(widget.controller.setAlbumOffsetMillis(0)),
          ),
          _OffsetStepSpec(
            key: const ValueKey('lyric_album_offset_plus_100'),
            label: '+0.1s',
            onTap: () => unawaited(
              widget.controller.setAlbumOffsetMillis(
                offset.albumOffsetMillis + 100,
              ),
            ),
          ),
          _OffsetStepSpec(
            key: const ValueKey('lyric_album_offset_plus_500'),
            label: '+0.5s',
            onTap: () => unawaited(
              widget.controller.setAlbumOffsetMillis(
                offset.albumOffsetMillis + 500,
              ),
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
                widget.controller.setRouteOffsetMillis(kind, millis - 100),
              ),
            ),
            KonataPillButton.secondary(
              key: ValueKey('${keyPrefix}_reset'),
              label: '归零',
              compact: true,
              onPressed: () => unawaited(
                widget.controller.setRouteOffsetMillis(kind, 0),
              ),
            ),
            KonataPillButton.secondary(
              key: ValueKey('${keyPrefix}_plus_100'),
              label: '+0.1s',
              compact: true,
              onPressed: () => unawaited(
                widget.controller.setRouteOffsetMillis(kind, millis + 100),
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
