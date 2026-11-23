import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../application/providers/bangumi_sync_providers.dart';
import '../../domain/formatting/network_error_sanitizer.dart';
import '../../domain/sync/bangumi_sync_models.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/konata_pill_button.dart';
import '../widgets/design_system/konata_segmented_capsule.dart';
import '../widgets/design_system/konata_soft_text_field.dart';
import '../widgets/design_system/konata_surface_card.dart';
import '../widgets/design_system/konata_switch.dart';
import '../widgets/design_system/konata_toast.dart';

/// Bangumi PAT 观看进度双向同步设置卡片（全端共用，嵌入「备份与同步」设置页）。
class SettingsBangumiSyncCard extends ConsumerStatefulWidget {
  /// 创建 Bangumi 观看进度同步卡片。
  const SettingsBangumiSyncCard({super.key});

  @override
  ConsumerState<SettingsBangumiSyncCard> createState() =>
      _SettingsBangumiSyncCardState();
}

class _SettingsBangumiSyncCardState
    extends ConsumerState<SettingsBangumiSyncCard> {
  final TextEditingController _patController = TextEditingController();
  bool _initialized = false;
  bool _obscureToken = true;
  Timer? _autoSaveTimer;

  @override
  void dispose() {
    _autoSaveTimer?.cancel();
    _patController.dispose();
    super.dispose();
  }

  void _syncControllerIfNeeded(BangumiSyncUiState syncState) {
    if (_initialized || !syncState.loaded) return;
    _initialized = true;
    _patController.text = syncState.config.personalAccessToken;
  }

  BangumiSyncConfig _draftConfig(BangumiSyncConfig base) {
    return base.copyWith(personalAccessToken: _patController.text.trim());
  }

  void _scheduleAutoSave() {
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(KonataTheme.settingsAutoSaveDebounce, () {
      if (!mounted) return;
      final current = ref.read(bangumiSyncControllerProvider).config;
      unawaited(
        ref
            .read(bangumiSyncControllerProvider.notifier)
            .saveConfig(_draftConfig(current)),
      );
    });
  }

  String _formatDateTime(DateTime dt) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}.${two(dt.month)}.${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}';
  }

  Future<void> _openTokenPortal() async {
    final uri = Uri.parse(BangumiSyncConfig.tokenPortalUrl);
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _handleVerifyToken() async {
    final current = ref.read(bangumiSyncControllerProvider).config;
    final draft = _draftConfig(current);
    try {
      final profile = await ref
          .read(bangumiSyncControllerProvider.notifier)
          .verifyToken(draft);
      if (mounted) {
        showKonataToast(context, 'Bangumi 账号验证成功：${profile.displayLabel}');
      }
    } catch (error) {
      if (mounted) {
        showKonataToast(
          context,
          NetworkErrorSanitizer.toUserMessage(error, prefix: '令牌验证失败'),
          isError: true,
        );
      }
    }
  }

  Future<void> _handleSyncAll() async {
    final current = ref.read(bangumiSyncControllerProvider).config;
    final draft = _draftConfig(current);
    try {
      final report = await ref
          .read(bangumiSyncControllerProvider.notifier)
          .syncAllLibrary(configOverride: draft);
      if (mounted) {
        showKonataToast(
          context,
          'Bangumi 同步完成：${report.toSummaryMessage()}',
          isError: report.worksFailed > 0 && report.worksSucceeded == 0,
        );
      }
    } catch (error) {
      if (mounted) {
        showKonataToast(
          context,
          NetworkErrorSanitizer.toUserMessage(error, prefix: 'Bangumi 同步失败'),
          isError: true,
        );
      }
    }
  }

  Future<void> _handleFlushQueue() async {
    try {
      final flushed = await ref
          .read(bangumiSyncControllerProvider.notifier)
          .flushQueueNow();
      if (mounted) {
        showKonataToast(context, '已补发 $flushed 条 Bangumi 离线进度记录');
      }
    } catch (error) {
      if (mounted) {
        showKonataToast(
          context,
          NetworkErrorSanitizer.toUserMessage(error, prefix: '重试上报失败'),
          isError: true,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final syncState = ref.watch(bangumiSyncControllerProvider);
    _syncControllerIfNeeded(syncState);

    final accentPink = p.isDark
        ? KonataTheme.bangumiPink
        : KonataTheme.bangumiPinkLightTheme;
    final lastSyncText = syncState.lastSyncAt == null
        ? '尚未同步'
        : '上次同步：${_formatDateTime(syncState.lastSyncAt!)}'
              '${syncState.lastSummary != null ? ' · ${syncState.lastSummary}' : ''}';

    return KonataSurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SizedBox(
                width: 38,
                height: 38,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: accentPink.withValues(alpha: 0.14),
                    borderRadius: KonataTheme.borderRadiusControl,
                    border: Border.all(
                      color: accentPink.withValues(alpha: 0.35),
                      width: 1,
                    ),
                  ),
                  child: Center(
                    child: Text(
                      'bgm',
                      style: TextStyle(
                        color: accentPink,
                        fontSize: KonataTheme.fontSizeBadge,
                        fontWeight: FontWeight.w800,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Bangumi 观看进度同步',
                      style: TextStyle(
                        color: p.textPrimary,
                        fontSize: KonataTheme.fontSizeTitle,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      syncState.profile != null
                          ? '已连接账号：${syncState.profile!.displayLabel}'
                          : '使用官方个人访问令牌（PAT）直连 api.bgm.tv 双向同步追番进度',
                      style: TextStyle(
                        color: syncState.profile != null
                            ? accentPink
                            : p.textSecondary,
                        fontSize: KonataTheme.fontSizeBodyXs,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              KonataSwitch(
                key: const ValueKey('settings_bangumi_sync_switch'),
                value: syncState.config.enabled,
                onChanged: (enabled) => ref
                    .read(bangumiSyncControllerProvider.notifier)
                    .saveConfig(
                      _draftConfig(
                        syncState.config,
                      ).copyWith(enabled: enabled),
                    ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          KonataSoftTextField(
            controller: _patController,
            label: '个人访问令牌（PAT，仅直连官方且安全加密存储）',
            hintText: '在 next.bgm.tv/demo/access-token 生成后粘贴',
            obscureText: _obscureToken,
            prefixIcon: Icons.vpn_key_outlined,
            suffix: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _obscureToken = !_obscureToken),
              child: Icon(
                _obscureToken
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                size: 18,
                color: p.textSecondary,
              ),
            ),
            onChanged: (_) => _scheduleAutoSave(),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: KonataPillButton.ghost(
              label: '前往 Bangumi 获取个人访问令牌',
              icon: Icons.open_in_new_rounded,
              compact: true,
              onPressed: _openTokenPortal,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '同步方向',
            style: TextStyle(
              color: p.textSecondary,
              fontSize: KonataTheme.fontSizeBodyXs,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 6),
          KonataSegmentedCapsule<BangumiSyncMode>(
            selected: syncState.config.syncMode,
            options: const [
              KonataSegmentOption(
                value: BangumiSyncMode.bidirectional,
                label: '双向同步',
              ),
              KonataSegmentOption(
                value: BangumiSyncMode.pushOnly,
                label: '仅上报进度',
              ),
            ],
            onChanged: (mode) => ref
                .read(bangumiSyncControllerProvider.notifier)
                .saveConfig(
                  _draftConfig(syncState.config).copyWith(syncMode: mode),
                ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: Text(
                  '看完一集后自动上报 Bangumi（离线自动入队重试）',
                  style: TextStyle(
                    color: p.textPrimary,
                    fontSize: KonataTheme.fontSizeBodySm,
                  ),
                ),
              ),
              KonataSwitch(
                value: syncState.config.autoPushOnComplete,
                onChanged: (value) => ref
                    .read(bangumiSyncControllerProvider.notifier)
                    .saveConfig(
                      _draftConfig(
                        syncState.config,
                      ).copyWith(autoPushOnComplete: value),
                    ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  '本篇全集看完后自动将条目标记为「看过」',
                  style: TextStyle(
                    color: p.textPrimary,
                    fontSize: KonataTheme.fontSizeBodySm,
                  ),
                ),
              ),
              KonataSwitch(
                value: syncState.config.autoMarkSubjectCompleted,
                onChanged: (value) => ref
                    .read(bangumiSyncControllerProvider.notifier)
                    .saveConfig(
                      _draftConfig(
                        syncState.config,
                      ).copyWith(autoMarkSubjectCompleted: value),
                    ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              KonataPillButton.secondary(
                key: const ValueKey('settings_bangumi_verify_token'),
                label: syncState.isVerifying ? '验证中...' : '验证令牌',
                icon: Icons.verified_user_outlined,
                compact: true,
                onPressed: syncState.isVerifying || syncState.isSyncing
                    ? null
                    : _handleVerifyToken,
              ),
              KonataPillButton.primary(
                key: const ValueKey('settings_bangumi_sync_all'),
                label: syncState.isSyncing ? '同步中...' : '立即全库同步',
                icon: Icons.sync_rounded,
                compact: true,
                onPressed: syncState.isSyncing || syncState.isVerifying
                    ? null
                    : _handleSyncAll,
              ),
              if (syncState.pendingQueueCount > 0)
                KonataPillButton.secondary(
                  key: const ValueKey('settings_bangumi_flush_queue'),
                  label: '补发待重试 (${syncState.pendingQueueCount})',
                  icon: Icons.cloud_upload_outlined,
                  compact: true,
                  onPressed: syncState.isSyncing ? null : _handleFlushQueue,
                ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            syncState.lastError ?? lastSyncText,
            style: TextStyle(
              color: syncState.lastError != null ? p.danger : p.textSecondary,
              fontSize: KonataTheme.fontSizeBodyXs,
            ),
          ),
        ],
      ),
    );
  }
}
