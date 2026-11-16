import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/playback/playback_dispatcher.dart';
import '../../application/playback/playback_preferences_provider.dart';
import '../../application/providers/library_providers.dart';
import '../../application/providers/playback_providers.dart';
import '../../application/providers/source_actions_provider.dart';
import '../../application/providers/work_management_provider.dart';
import '../../domain/matching/episode_title_formatter.dart';
import '../../domain/matching/playback_resume_resolver.dart';
import '../../domain/models/episode.dart';
import '../../domain/models/external_player_config.dart';
import '../../domain/models/media_source.dart';
import '../../domain/models/media_variant.dart';
import '../../domain/models/work.dart';
import '../dialogs/delete_work_dialog.dart';
import '../dialogs/manual_match_dialog.dart';
import '../dialogs/series_manage_dialog.dart';
import '../dialogs/work_artwork_picker_dialog.dart';
import '../dialogs/work_manual_edit_dialog.dart';
import '../dialogs/work_merge_target_dialog.dart';
import '../video/embedded_video_page.dart';
import '../widgets/design_system/konata_glass_dialog.dart';
import '../widgets/design_system/konata_pill_button.dart';
import '../widgets/design_system/konata_segmented_capsule.dart';
import '../widgets/design_system/konata_soft_text_field.dart';
import '../widgets/design_system/konata_toast.dart';
import 'supplementary_asset_cards.dart';
import 'variant_picker_dialog.dart';

/// 作品详情页弹窗与管理操作辅助函数（保持页面组件精简，严格 < 450 行）。
class DetailActionHandlers {
  const DetailActionHandlers._();

  /// 根据最近进度触发主按钮智能续播或自动推进下一集。
  static Future<void> handlePrimaryPlay({
    required BuildContext context,
    required WidgetRef ref,
    required WorkDetailBundle bundle,
    required List<ExternalPlayerConfig> players,
  }) async {
    final plan = PlaybackResumeResolver.resolve(
      episodes: bundle.episodes,
      latestPlayback: bundle.latestPlayback,
      playbackByEpisodeId: bundle.playbackByEpisodeId,
      workTitle: bundle.work.title,
      workMediaType: bundle.work.tmdbMediaType,
    );
    if (plan == null) {
      showKonataToast(context, '当前作品暂无可播放剧集');
      return;
    }
    await playEpisode(
      context: context,
      ref: ref,
      bundle: bundle,
      episode: plan.targetEpisode,
      players: players,
      startSeconds: plan.startSeconds,
    );
  }

  /// 播放指定逻辑集（单版本直出或弹出版本选择器，并自动带入断点秒数）。
  static Future<void> playEpisode({
    required BuildContext context,
    required WidgetRef ref,
    required WorkDetailBundle bundle,
    required Episode episode,
    required List<ExternalPlayerConfig> players,
    int? startSeconds,
    PreferredPlaybackEngine? overrideEngine,
    ExternalPlayerConfig? explicitPlayer,
  }) async {
    final variants = bundle.variantsForEpisode(episode.id);
    if (variants.isEmpty) {
      showKonataToast(context, '该剧集暂无可用视频文件');
      return;
    }
    final saved = bundle.playbackByEpisodeId[episode.id];
    final effectiveStart = startSeconds ??
        ((saved != null && !saved.isCompleted && saved.positionSeconds > 5)
            ? saved.positionSeconds
            : 0);
    if (variants.length == 1) {
      await launchVariant(
        context: context,
        ref: ref,
        bundle: bundle,
        episode: episode,
        variant: variants.first,
        player: explicitPlayer,
        overrideEngine: overrideEngine,
        startSeconds: effectiveStart,
      );
      return;
    }
    await showKonataGlassDialog<void>(
      context: context,
      builder: (_) => VariantPickerDialog(
        episode: episode,
        variants: variants,
        sourcesById: bundle.sourcesById,
        players: players,
        initialEngine: overrideEngine,
        initialPlayer: explicitPlayer,
        onPlay: (variant, pickedEngine, player) {
          launchVariant(
            context: context,
            ref: ref,
            bundle: bundle,
            episode: episode,
            variant: variant,
            player: player,
            overrideEngine: pickedEngine,
            startSeconds: effectiveStart,
          );
        },
      ),
    );
  }

  /// 通过统一播放分发器拉起内置高保真内核或外部播放器并回写进度。
  static Future<void> launchVariant({
    required BuildContext context,
    required WidgetRef ref,
    required WorkDetailBundle bundle,
    required Episode episode,
    required MediaVariant variant,
    required ExternalPlayerConfig? player,
    PreferredPlaybackEngine? overrideEngine,
    int startSeconds = 0,
  }) async {
    final navigator = Navigator.of(context);
    final decision = await ref
        .read(playbackDispatcherProvider)
        .dispatchVideoVariant(
          bundle: bundle,
          episode: episode,
          variant: variant,
          startSeconds: startSeconds,
          overrideEngine: overrideEngine,
          explicitPlayer: player,
        );
    switch (decision) {
      case OpenBuiltinVideoDecision(:final request):
        await EmbeddedVideoPage.push(navigator, request);
      case LaunchedExternalVideoDecision(:final result):
        if (context.mounted && result.message.isNotEmpty) {
          showKonataToast(context, result.message, isError: !result.launched);
        }
    }
  }

  /// 手动将剧集标记为「已看完」。
  static Future<void> markEpisodeCompleted({
    required BuildContext context,
    required WidgetRef ref,
    required WorkDetailBundle bundle,
    required Episode episode,
  }) async {
    final variants = bundle.variantsForEpisode(episode.id);
    final firstVariant = variants.isNotEmpty ? variants.first : null;
    final sourceType = firstVariant != null
        ? (bundle.sourcesById[firstVariant.sourceId]?.kind ??
              MediaSourceKind.local)
        : MediaSourceKind.local;
    await ref.read(playbackCoordinatorProvider).markEpisodeCompleted(
          work: bundle.work,
          episode: episode,
          variant: firstVariant,
          sourceType: sourceType,
        );
    if (context.mounted) {
      final mainCount = bundle.episodes
          .where((e) => e.category == EpisodeCategory.main)
          .length;
      final label = EpisodeTitleFormatter.formatCardTitle(
        episode: episode,
        workTitle: bundle.work.title,
        workMediaType: bundle.work.tmdbMediaType,
        mainEpisodeCount: mainCount,
      );
      showKonataToast(context, '已标记 $label 为已看完');
    }
  }

  /// 详情页顶部待复核横幅快速「忽略提示」。
  static Future<void> dismissReviewPrompt({
    required BuildContext context,
    required WidgetRef ref,
    required String workId,
  }) async {
    await ref.read(workManagementProvider).dismissWorkReview(workId);
    if (context.mounted) {
      showKonataToast(context, '已忽略待复核提示');
    }
  }

  /// 打开「微调单集季号/集号/分类」弹窗。
  static Future<void> showAdjustEpisodeDialog({
    required BuildContext context,
    required WidgetRef ref,
    required Episode episode,
  }) async {
    final seasonController = TextEditingController(
      text: episode.seasonNumber.toString(),
    );
    final epController = TextEditingController(
      text: episode.episodeNumber?.toString() ?? '',
    );
    var category = episode.category;

    final confirmed = await showKonataGlassDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => KonataGlassDialog(
          width: 390,
          title: '微调单集编号与分类',
          onClose: () => Navigator.of(ctx).pop(false),
          actions: [
            KonataPillButton.ghost(
              label: '取消',
              compact: true,
              onPressed: () => Navigator.of(ctx).pop(false),
            ),
            KonataPillButton.primary(
              label: '保存',
              compact: true,
              onPressed: () => Navigator.of(ctx).pop(true),
            ),
          ],
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              KonataSegmentedCapsule<EpisodeCategory>(
                options: const [
                  KonataSegmentOption(
                    value: EpisodeCategory.main,
                    label: '正片',
                  ),
                  KonataSegmentOption(
                    value: EpisodeCategory.extra,
                    label: '特典',
                  ),
                ],
                selected: category,
                onChanged: (v) => setDialogState(() => category = v),
              ),
              const SizedBox(height: 14),
              KonataSoftTextField(
                controller: seasonController,
                label: '季号 (Season)',
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 10),
              KonataSoftTextField(
                controller: epController,
                label: '集号 (Episode)',
                keyboardType: TextInputType.number,
              ),
            ],
          ),
        ),
      ),
    );

    if (confirmed == true) {
      final s = int.tryParse(seasonController.text.trim());
      final e = int.tryParse(epController.text.trim());
      if (s != null && e != null) {
        await ref
            .read(konataActionsProvider)
            .updateEpisodeSlot(
              episode: episode,
              seasonNumber: s,
              episodeNumber: e,
              category: category,
              extraType: episode.extraType ?? ExtraKind.sp,
            );
      }
    }
  }

  /// 打开「绑定元数据」弹窗。
  static Future<Work?> openManualMatch(
    BuildContext context,
    WorkDetailBundle bundle,
  ) {
    return showKonataGlassDialog<Work>(
      context: context,
      builder: (_) => ManualMatchDialog(
        workId: bundle.work.id,
        initialQuery: bundle.work.title,
      ),
    );
  }

  /// 打开「手动编辑信息与文件映射」弹窗（若操作导致原作品被合并或清空，返回重定向目标作品 ID）。
  static Future<String?> openManualEdit(
    BuildContext context,
    WorkDetailBundle bundle,
  ) {
    return showKonataGlassDialog<String?>(
      context: context,
      builder: (_) => WorkManualEditDialog(bundle: bundle),
    );
  }

  /// 打开「合并整部作品至其他条目」选择器弹窗。
  static Future<WorkMergeOutcome?> openMergeWork(
    BuildContext context,
    WorkDetailBundle bundle,
  ) {
    final hasMain = bundle.episodes.any((e) => e.category == EpisodeCategory.main);
    return showKonataGlassDialog<WorkMergeOutcome>(
      context: context,
      builder: (_) => WorkMergeTargetDialog(
        sourceWorkId: bundle.work.id,
        sourceWorkTitle: bundle.work.title,
        initialMode: hasMain
            ? MergeVideoCategoryMode.preserve
            : MergeVideoCategoryMode.asExtra,
      ),
    );
  }

  /// 打开「编辑封面」或「编辑背景图」选择器。
  static Future<void> openArtworkPicker(
    BuildContext context,
    WorkDetailBundle bundle,
    WorkArtworkKind kind,
  ) {
    return showKonataGlassDialog<void>(
      context: context,
      builder: (_) => WorkArtworkPickerDialog(work: bundle.work, kind: kind),
    );
  }

  /// 隐藏作品并退出详情页。
  static Future<void> hideWorkAndPop(
    BuildContext context,
    WidgetRef ref,
    WorkDetailBundle bundle,
  ) async {
    await ref.read(workManagementProvider).hideWork(bundle.work.id);
    if (context.mounted) {
      showKonataToast(
        context,
        '已隐藏「${bundle.work.title}」，可在 设置 -> 外观与显示 中恢复',
      );
      Navigator.of(context).maybePop();
    }
  }

  /// 二次确认后仅从媒体库移除作品记录（绝不删源视频文件）。
  static Future<void> confirmDeleteAndPop(
    BuildContext context,
    WidgetRef ref,
    WorkDetailBundle bundle,
  ) async {
    final res = await showKonataGlassDialog<DeleteWorkConfirmResult>(
      context: context,
      builder: (_) => DeleteWorkDialog(workTitle: bundle.work.title),
    );
    if (res == null || !res.confirmed) return;
    await ref
        .read(workManagementProvider)
        .deleteWorkFromLibrary(
          bundle.work.id,
          addToIgnoreList: res.addToIgnoreList,
        );
    if (context.mounted) {
      showKonataToast(context, '已从媒体库移除「${bundle.work.title}」');
      Navigator.of(context).maybePop();
    }
  }

  /// 尝试打开作品首个本地文件所在的操作系统文件夹。
  static Future<void> openLocalDirectory(
    BuildContext context,
    WidgetRef ref,
    WorkDetailBundle bundle,
  ) async {
    final firstLocal = bundle.variants.where((v) {
      return bundle.sourcesById[v.sourceId]?.kind == MediaSourceKind.local;
    }).firstOrNull;
    if (firstLocal == null) {
      showKonataToast(context, '当前作品不包含本地磁盘文件');
      return;
    }
    final source = bundle.sourcesById[firstLocal.sourceId]!;
    final opened = await ref
        .read(konataActionsProvider)
        .openLocalContainingFolder(
          source: source,
          relativePath: firstLocal.relativePath,
        );
    if (!opened && context.mounted) {
      showKonataToast(context, '无法定位本地目录: ${source.location}');
    }
  }

  /// 打开「管理系列编组」弹窗，自由合并同系列作品并配置自定义或预设标签。
  static Future<void> openSeriesManage(
    BuildContext context,
    WorkDetailBundle bundle,
  ) {
    return showKonataGlassDialog<void>(
      context: context,
      builder: (_) => SeriesManageDialog(bundle: bundle),
    );
  }

  /// 通过统一播放分发器播放附属音乐 CD 音轨（支持默认/内置流光页/外部播放器）。
  static Future<void> playCdAsset({
    required BuildContext context,
    required WidgetRef ref,
    required WorkDetailBundle bundle,
    required MediaVariant variant,
    PreferredPlaybackEngine? overrideEngine,
    ExternalPlayerConfig? explicitPlayer,
    bool expandImmersive = false,
  }) async {
    final res = await ref
        .read(playbackDispatcherProvider)
        .playCdVariant(
          work: bundle.work,
          variant: variant,
          cdPlaylist: bundle.cdVariants,
          sourcesById: bundle.sourcesById,
          overrideEngine: overrideEngine,
          explicitPlayer: explicitPlayer,
          expandImmersive: expandImmersive,
        );
    if (context.mounted && res.message.isNotEmpty) {
      showKonataToast(context, res.message, isError: !res.launched);
    }
  }

  /// 打开 Scan 画集毛玻璃全屏缩放预览弹窗。
  static Future<void> openScanViewer(
    BuildContext context,
    WorkDetailBundle bundle,
    MediaVariant variant,
  ) {
    return showKonataGlassDialog<void>(
      context: context,
      builder: (_) => ScanLightboxDialog(bundle: bundle, initialVariant: variant),
    );
  }
}
