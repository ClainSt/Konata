import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../application/providers/sync_providers.dart';
import '../../application/sync/konata_backup_service.dart';
import '../../domain/formatting/network_error_sanitizer.dart';
import '../../domain/sync/konata_sync_models.dart';
import '../theme/konata_adaptive_tokens.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/konata_dropdown.dart';
import '../widgets/design_system/konata_glass_dialog.dart';
import '../widgets/design_system/konata_pill_button.dart';
import '../widgets/design_system/konata_segmented_capsule.dart';
import '../widgets/design_system/konata_soft_text_field.dart';
import '../widgets/design_system/konata_surface_card.dart';
import '../widgets/design_system/konata_switch.dart';
import '../widgets/design_system/konata_system_file_picker.dart';
import '../widgets/design_system/konata_toast.dart';
import 'settings_shared_widgets.dart';

/// 备份与同步设置面板（本地 `.konata` 备份恢复 + WebDAV 多设备分片同步）。
class SettingsBackupSyncPanel extends ConsumerStatefulWidget {
  /// 创建备份与同步设置面板。
  const SettingsBackupSyncPanel({super.key, this.extraSection});

  /// 可选追加的扩展同步卡片（例如 Bangumi 观看进度同步卡片）。
  final Widget? extraSection;

  @override
  ConsumerState<SettingsBackupSyncPanel> createState() =>
      _SettingsBackupSyncPanelState();
}

class _SettingsBackupSyncPanelState
    extends ConsumerState<SettingsBackupSyncPanel> {
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _dirController = TextEditingController();
  final TextEditingController _userController = TextEditingController();
  final TextEditingController _passController = TextEditingController();

  bool _initializedForm = false;
  bool _obscurePassword = true;
  bool _exportingBackup = false;
  bool _restoringBackup = false;
  bool _hasPendingSave = false;
  Timer? _autoSaveTimer;
  WebDavSyncController? _syncController;
  WebDavSyncConfig _lastKnownConfig = const WebDavSyncConfig();
  String? _testResultText;
  bool _testResultIsError = false;

  @override
  void dispose() {
    _autoSaveTimer?.cancel();
    if (_hasPendingSave && _syncController != null) {
      _hasPendingSave = false;
      unawaited(_syncController!.saveConfig(_draftConfig(_lastKnownConfig)));
    }
    _urlController.dispose();
    _dirController.dispose();
    _userController.dispose();
    _passController.dispose();
    super.dispose();
  }

  void _syncControllersIfNeeded(WebDavSyncUiState syncState) {
    _syncController = ref.read(webDavSyncControllerProvider.notifier);
    _lastKnownConfig = syncState.config;
    if (_initializedForm || !syncState.loaded) return;
    _initializedForm = true;
    _urlController.text = syncState.config.baseUrl;
    _dirController.text = syncState.config.normalizedRemoteDir;
    _userController.text = syncState.config.username;
    _passController.text = syncState.config.password;
  }

  WebDavSyncConfig _draftConfig(WebDavSyncConfig base) {
    return base.copyWith(
      baseUrl: _urlController.text.trim(),
      remoteDir: _dirController.text.trim().isEmpty
          ? WebDavSyncConfig.defaultRemoteDir
          : _dirController.text.trim(),
      username: _userController.text.trim(),
      password: _passController.text,
    );
  }

  void _scheduleSaveConfig() {
    _hasPendingSave = true;
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(KonataTheme.settingsAutoSaveDebounce, () {
      if (!mounted) return;
      _hasPendingSave = false;
      final current = ref.read(webDavSyncControllerProvider).config;
      unawaited(
        ref
            .read(webDavSyncControllerProvider.notifier)
            .saveConfig(_draftConfig(current)),
      );
    });
  }

  Future<void> _exportBackup() async {
    if (_exportingBackup) return;
    setState(() => _exportingBackup = true);
    try {
      final backupService = ref.read(konataBackupServiceProvider);
      final localPreview = await backupService.inspectCurrentLocalData();
      if (!mounted) return;

      final selectedScope = await _showExportOptionsDialog(localPreview);
      if (selectedScope == null || !mounted) return;

      final bytes = await backupService.exportKonataArchiveBytes(
        scope: selectedScope,
      );
      final uri = await ref.read(konataSystemFilePickerProvider).saveFile(
        dialogTitle: '导出 Konata 本地备份',
        fileName: 'konata_backup_${buildKonataFileTimestampSuffix()}.konata',
        bytes: bytes,
      );
      if (uri == null || !mounted) return;
      final pathText = uri.isScheme('file') ? uri.toFilePath() : uri.toString();
      showKonataToast(
        context,
        '已导出备份（${selectedScope.describeLabel()}）至 $pathText',
      );
    } catch (error) {
      if (mounted) {
        showKonataToast(
          context,
          NetworkErrorSanitizer.toUserMessage(error, prefix: '导出备份失败'),
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _exportingBackup = false);
    }
  }

  Future<KonataSyncDataScope?> _showExportOptionsDialog(
    KonataBackupPreview preview,
  ) {
    final hasLibraryData =
        preview.catalogWorkCount > 0 ||
        preview.catalogSourceCount > 0 ||
        preview.workOverrideCount > 0;
    var scope = KonataSyncDataScope(
      includePlaybacks: preview.playbackCount > 0 || preview.tombstoneCount > 0,
      includeWorkOverrides: hasLibraryData,
      includePreferences: preview.preferenceCount > 0,
    );
    if (!scope.hasAnySelected) {
      scope = KonataSyncDataScope.all;
    }
    return showKonataGlassDialog<KonataSyncDataScope>(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final p = ctx.palette;
          return KonataGlassDialog(
            title: '选择导出备份内容',
            width: 480,
            actions: [
              KonataPillButton.ghost(
                label: '取消',
                onPressed: () => Navigator.of(dialogCtx).pop(),
              ),
              KonataPillButton.primary(
                key: const ValueKey('backup_export_confirm_btn'),
                label: '选择保存位置',
                onPressed: scope.hasAnySelected
                    ? () => Navigator.of(dialogCtx).pop(scope)
                    : null,
              ),
            ],
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '自由勾选需要写入 .konata 备份文件的数据分类（支持导出完整已整理媒体库与媒体源结构，始终自动剥离密码与 API 密钥，附带 SHA-256 完整性校验）。',
                  style: TextStyle(
                    color: p.textSecondary,
                    fontSize: KonataTheme.fontSizeBodySm,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 14),
                _SyncDataScopeSwitches(
                  keyPrefix: 'export_scope',
                  scope: scope,
                  preview: preview,
                  disableWhenEmpty: false,
                  onChanged: (next) => setDialogState(() => scope = next),
                ),
                if (!scope.hasAnySelected) ...[
                  const SizedBox(height: 10),
                  Text(
                    '请至少勾选一项要导出的内容',
                    style: TextStyle(
                      color: p.danger,
                      fontSize: KonataTheme.fontSizeBodyXs,
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _importBackup() async {
    if (_restoringBackup) return;
    setState(() => _restoringBackup = true);
    try {
      final picked = await ref.read(konataSystemFilePickerProvider).pickFiles(
        dialogTitle: '选择要恢复的 .konata 备份文件',
        type: FileType.custom,
        allowedExtensions: KonataBackupService.backupFileExtensions,
        allowMultiple: false,
      );
      if (picked.isEmpty || !mounted) return;
      final file = picked.first;
      if (!KonataSystemFilePicker.matchesAllowedExtension(
        file.name,
        KonataBackupService.backupFileExtensions,
        allowNoExtension: true,
      )) {
        showKonataToast(
          context,
          '请选择 .konata 或 .json 备份文件（当前选择了：${file.name}）',
          isError: true,
        );
        return;
      }
      final fileLength = await file.length();
      if (!mounted) return;
      if (fileLength != null &&
          fileLength > KonataBackupService.maxBackupArchiveBytes) {
        showKonataToast(
          context,
          '所选文件过大，请确认选择的是 Konata 备份文件',
          isError: true,
        );
        return;
      }
      final bytes = await file.readAsBytes();
      final preview = await ref
          .read(konataBackupServiceProvider)
          .inspectKonataArchiveForLocalDevice(bytes);
      if (!mounted) return;

      final choice = await _showRestoreConfirmDialog(preview);
      if (choice == null || !mounted) return;

      final outcome = await ref
          .read(webDavSyncControllerProvider.notifier)
          .restoreLocalBackup(
            bytes,
            mode: choice.mode,
            scope: choice.scope,
          );
      if (mounted) {
        showKonataToast(
          context,
          '恢复完成：${outcome.toSummaryMessage()}',
          duration: outcome.needsExtendedToast
              ? KonataAdaptiveTokens.toastExtendedDismissDuration
              : KonataAdaptiveTokens.toastAutoDismissDuration,
        );
      }
    } catch (error) {
      if (mounted) {
        showKonataToast(
          context,
          NetworkErrorSanitizer.toUserMessage(error, prefix: '导入恢复失败'),
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _restoringBackup = false);
    }
  }

  Future<({KonataBackupRestoreMode mode, KonataSyncDataScope scope})?>
  _showRestoreConfirmDialog(KonataBackupPreview preview) {
    var mode = KonataBackupRestoreMode.smartMerge;
    final hasLibraryData =
        preview.hasLibraryCatalog || preview.workOverrideCount > 0;
    var scope = KonataSyncDataScope(
      includePlaybacks: preview.playbackCount > 0 || preview.tombstoneCount > 0,
      includeWorkOverrides: hasLibraryData,
      includePreferences: preview.preferenceCount > 0,
    );
    return showKonataGlassDialog<
      ({KonataBackupRestoreMode mode, KonataSyncDataScope scope})
    >(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final p = ctx.palette;
          final showStrategy =
              scope.includePlaybacks ||
              (scope.includeWorkOverrides && preview.hasLibraryCatalog);
          final catalogNoticeText = _buildCatalogRestoreHint(preview);
          return KonataGlassDialog(
            title: '确认恢复本地备份',
            width: 500,
            actions: [
              KonataPillButton.ghost(
                label: '取消',
                onPressed: () => Navigator.of(dialogCtx).pop(),
              ),
              KonataPillButton.primary(
                key: const ValueKey('backup_restore_confirm_btn'),
                label: '开始恢复',
                onPressed: scope.hasAnySelected
                    ? () => Navigator.of(dialogCtx).pop((
                        mode: mode,
                        scope: scope,
                      ))
                    : null,
              ),
            ],
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '来源：${preview.deviceName} · ${formatKonataShortDateTime(preview.exportedAt)}',
                  style: TextStyle(
                    color: p.textMuted,
                    fontSize: KonataTheme.fontSizeBodyXs,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '已通过 SHA-256 完整性校验，请勾选需要恢复到本机的数据项（不含任何密码或密钥，不修改物理媒体文件）。',
                  style: TextStyle(
                    color: p.textSecondary,
                    fontSize: KonataTheme.fontSizeBodySm,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  '恢复内容',
                  style: TextStyle(
                    color: p.textPrimary,
                    fontSize: KonataTheme.fontSizeBodySm,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                _SyncDataScopeSwitches(
                  keyPrefix: 'restore_scope',
                  scope: scope,
                  preview: preview,
                  disableWhenEmpty: true,
                  onChanged: (next) => setDialogState(() => scope = next),
                ),
                if (catalogNoticeText != null &&
                    scope.includeWorkOverrides) ...[
                  const SizedBox(height: 12),
                  Container(
                    key: const ValueKey('backup_restore_catalog_notice'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: p.accent.withValues(alpha: 0.10),
                      borderRadius: KonataTheme.borderRadiusSm,
                      border: Border.all(
                        color: p.accent.withValues(alpha: 0.30),
                        width: KonataAdaptiveTokens.borderWidth,
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: Icon(
                            Icons.info_outline_rounded,
                            size: 16,
                            color: p.accent,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            catalogNoticeText,
                            style: TextStyle(
                              color: p.textSecondary,
                              fontSize: KonataTheme.fontSizeBodyXs,
                              height: 1.45,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ] else if (preview.hasUnmatchedEntries) ...[
                  const SizedBox(height: 12),
                  Container(
                    key: const ValueKey('backup_restore_unmatched_notice'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: p.warning.withValues(alpha: 0.12),
                      borderRadius: KonataTheme.borderRadiusSm,
                      border: Border.all(
                        color: p.warning.withValues(alpha: 0.34),
                        width: KonataAdaptiveTokens.borderWidth,
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: Icon(
                            Icons.info_outline_rounded,
                            size: 16,
                            color: p.warning,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '此备份为旧版精简格式（不含完整媒体库目录），本机当前共 ${preview.localWorkCount ?? 0} 部作品，未入库条目将自动跳过。'
                            '请在源设备更新至新版后重新导出 .konata 或开启 WebDAV 同步，即可直接还原整套已整理媒体库。',
                            style: TextStyle(
                              color: p.textSecondary,
                              fontSize: KonataTheme.fontSizeBodyXs,
                              height: 1.45,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                if (!scope.hasAnySelected) ...[
                  const SizedBox(height: 8),
                  Text(
                    '请至少勾选一项要恢复的数据',
                    style: TextStyle(
                      color: p.danger,
                      fontSize: KonataTheme.fontSizeBodyXs,
                    ),
                  ),
                ],
                if (showStrategy) ...[
                  const SizedBox(height: 16),
                  Text(
                    '恢复策略',
                    style: TextStyle(
                      color: p.textPrimary,
                      fontSize: KonataTheme.fontSizeBodySm,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  KonataSegmentedCapsule<KonataBackupRestoreMode>(
                    selected: mode,
                    options: const [
                      KonataSegmentOption(
                        value: KonataBackupRestoreMode.smartMerge,
                        label: '智能合并（推荐）',
                      ),
                      KonataSegmentOption(
                        value: KonataBackupRestoreMode.overwrite,
                        label: '覆盖还原',
                      ),
                    ],
                    onChanged: (next) => setDialogState(() => mode = next),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    mode == KonataBackupRestoreMode.smartMerge
                        ? '合并两端已整理媒体库与观看进度，保留本机已有作品与媒体源密码并同步新增及最新变更。'
                        : '按备份快照重建所勾选的媒体库或播放记录（保留同址媒体源密码，绝不删除物理媒体文件）。',
                    style: TextStyle(
                      color: p.textMuted,
                      fontSize: KonataTheme.fontSizeBodyXs,
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  String? _buildCatalogRestoreHint(KonataBackupPreview preview) {
    if (!preview.hasLibraryCatalog) return null;
    final parts = <String>[
      '将直接还原 ${preview.catalogWorkCount} 部已整理作品、${preview.catalogEpisodeCount} 条剧集与 ${preview.catalogSourceCount} 个媒体源（封面与背景图按需自动拉取缓存，无需重新刮削）。',
    ];
    if (preview.remoteSourcesNeedingPassword > 0) {
      parts.add(
        '新增的 ${preview.remoteSourcesNeedingPassword} 个带账号远程源不含密码，如需认证请恢复后前往「媒体源」补填。',
      );
    }
    if (KonataAdaptiveTokens.isAndroid && preview.catalogLocalSourceCount > 0) {
      parts.add(
        '备份含本地磁盘目录源；如需在手机直接播放，可在「媒体源」点击编辑将其切换为对应的 WebDAV/SMB 地址。',
      );
    }
    return parts.join('');
  }

  Future<void> _handleTestConnection() async {
    final current = ref.read(webDavSyncControllerProvider).config;
    final draft = _draftConfig(current);
    await ref.read(webDavSyncControllerProvider.notifier).saveConfig(draft);
    final err = await ref
        .read(webDavSyncControllerProvider.notifier)
        .testConnection(draft);
    if (!mounted) return;
    setState(() {
      _testResultIsError = err != null;
      _testResultText = err ?? 'WebDAV 同步目录连通正常，可正常读写分片';
    });
    showKonataToast(
      context,
      _testResultText!,
      isError: _testResultIsError,
    );
  }

  Future<void> _handleSyncNow() async {
    final current = ref.read(webDavSyncControllerProvider).config;
    final draft = _draftConfig(current);
    try {
      final outcome = await ref
          .read(webDavSyncControllerProvider.notifier)
          .syncNow(configOverride: draft);
      if (mounted) {
        showKonataToast(
          context,
          '多设备同步完成：${outcome.toSummaryMessage()}',
          duration: outcome.needsExtendedToast
              ? KonataAdaptiveTokens.toastExtendedDismissDuration
              : KonataAdaptiveTokens.toastAutoDismissDuration,
        );
      }
    } catch (error) {
      if (mounted) {
        showKonataToast(
          context,
          NetworkErrorSanitizer.toUserMessage(error, prefix: 'WebDAV 同步失败'),
          isError: true,
        );
      }
    }
  }

  Widget _buildLeadingBox(KonataPalette p, IconData icon) =>
      KonataSettingsLeadingBox(
        child: Icon(icon, size: 20, color: p.textSecondary),
      );

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final syncState = ref.watch(webDavSyncControllerProvider);
    _syncControllersIfNeeded(syncState);

    final lastSyncText = syncState.lastSyncAt == null
        ? '尚未同步'
        : '上次同步：${formatKonataShortDateTime(syncState.lastSyncAt!)}'
              '${syncState.lastSummary != null ? ' · ${syncState.lastSummary}' : ''}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KonataSurfaceCard(
          padding: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              KonataListTile(
                key: const ValueKey('settings_export_konata_backup'),
                title: '导出本地备份 (.konata)',
                subtitle: '可自选完整已整理媒体库、观看进度与便携偏好导出（自动剥离密码与密钥，带 SHA-256 校验）',
                leading: _buildLeadingBox(p, Icons.archive_outlined),
                trailing: Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: p.textMuted,
                ),
                onTap: _exportingBackup ? null : _exportBackup,
              ),
              Divider(height: 1, color: p.hairline, indent: 18, endIndent: 18),
              KonataListTile(
                key: const ValueKey('settings_import_konata_backup'),
                title: '从备份文件恢复 (.konata)',
                subtitle: _restoringBackup
                    ? '正在校验并恢复备份数据，请稍候...'
                    : '导入前校验完整性，支持直接还原整套已整理媒体库、观看进度与偏好设置，绝不触碰物理媒体文件',
                leading: _buildLeadingBox(p, Icons.unarchive_outlined),
                trailing: Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: p.textMuted,
                ),
                onTap: _restoringBackup ? null : _importBackup,
              ),
              if (syncState.lastBackupAt != null &&
                  syncState.lastBackupSummary != null) ...[
                Divider(height: 1, color: p.hairline, indent: 18, endIndent: 18),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 10, 18, 12),
                  child: Text(
                    '上次本地恢复：${formatKonataShortDateTime(syncState.lastBackupAt!)} · ${syncState.lastBackupSummary!}',
                    key: const ValueKey('settings_local_backup_last_status'),
                    style: TextStyle(
                      color: p.textSecondary,
                      fontSize: KonataTheme.fontSizeBodyXs,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        KonataSurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  _buildLeadingBox(p, Icons.cloud_sync_outlined),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'WebDAV 多设备分片同步',
                          style: TextStyle(
                            color: p.textPrimary,
                            fontSize: KonataTheme.fontSizeTitle,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '每台设备独立写入专属分片，跨 Windows 与 Android 零锁冲突同步完整已整理媒体库、观看进度与偏好',
                          style: TextStyle(
                            color: p.textSecondary,
                            fontSize: KonataTheme.fontSizeBodyXs,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  KonataSwitch(
                    key: const ValueKey('settings_webdav_sync_switch'),
                    value: syncState.config.enabled,
                    onChanged: (enabled) => ref
                        .read(webDavSyncControllerProvider.notifier)
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
                controller: _urlController,
                label: 'WebDAV 服务器地址',
                hintText: 'https://dav.example.com/dav',
                prefixIcon: Icons.link_rounded,
                onChanged: (_) => _scheduleSaveConfig(),
              ),
              const SizedBox(height: 12),
              KonataSoftTextField(
                controller: _dirController,
                label: '远端同步子目录',
                hintText: WebDavSyncConfig.defaultRemoteDir,
                prefixIcon: Icons.folder_outlined,
                onChanged: (_) => _scheduleSaveConfig(),
              ),
              const SizedBox(height: 12),
              KonataSoftTextField(
                controller: _userController,
                label: '用户名（可选）',
                hintText: 'WebDAV 账号',
                prefixIcon: Icons.person_outline_rounded,
                onChanged: (_) => _scheduleSaveConfig(),
              ),
              const SizedBox(height: 12),
              KonataSoftTextField(
                controller: _passController,
                label: '密码（安全加密保存，不参与备份）',
                hintText: 'WebDAV 密码或应用专用密码',
                obscureText: _obscurePassword,
                prefixIcon: Icons.lock_outline_rounded,
                suffix: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () =>
                      setState(() => _obscurePassword = !_obscurePassword),
                  child: Icon(
                    _obscurePassword
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    size: 18,
                    color: p.textSecondary,
                  ),
                ),
                onChanged: (_) => _scheduleSaveConfig(),
              ),
              const SizedBox(height: 16),
              Divider(height: 1, color: p.hairline),
              const SizedBox(height: 14),
              Text(
                '同步内容',
                style: TextStyle(
                  color: p.textPrimary,
                  fontSize: KonataTheme.fontSizeBodySm,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
              _SyncDataScopeSwitches(
                keyPrefix: 'webdav_scope',
                scope: syncState.config.syncScope,
                onChanged: (nextScope) {
                  _hasPendingSave = false;
                  ref
                      .read(webDavSyncControllerProvider.notifier)
                      .saveConfig(
                        _draftConfig(
                          syncState.config,
                        ).copyWith(syncScope: nextScope),
                      );
                },
              ),
              if (!syncState.config.syncScope.hasAnySelected) ...[
                const SizedBox(height: 8),
                Text(
                  '请至少开启一项要同步的数据内容',
                  style: TextStyle(
                    color: p.danger,
                    fontSize: KonataTheme.fontSizeBodyXs,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Divider(height: 1, color: p.hairline),
              const SizedBox(height: 14),
              Text(
                '自动同步策略',
                style: TextStyle(
                  color: p.textPrimary,
                  fontSize: KonataTheme.fontSizeBodySm,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
              KonataSettingsSwitchRow(
                label: '启动时自动同步',
                value: syncState.config.autoSyncOnStartup,
                onChanged: (value) {
                  _hasPendingSave = false;
                  ref
                      .read(webDavSyncControllerProvider.notifier)
                      .saveConfig(
                        _draftConfig(
                          syncState.config,
                        ).copyWith(autoSyncOnStartup: value),
                      );
                },
              ),
              const SizedBox(height: 10),
              KonataSettingsSwitchRow(
                label: '停播后静默上传进度',
                value: syncState.config.autoSyncOnPlaybackStop,
                onChanged: (value) {
                  _hasPendingSave = false;
                  ref
                      .read(webDavSyncControllerProvider.notifier)
                      .saveConfig(
                        _draftConfig(
                          syncState.config,
                        ).copyWith(autoSyncOnPlaybackStop: value),
                      );
                },
              ),
              const SizedBox(height: 12),
              _buildPeriodicIntervalRow(p, syncState.config),
              const SizedBox(height: 16),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  KonataPillButton.secondary(
                    key: const ValueKey('settings_webdav_sync_test'),
                    label: syncState.isTesting ? '测试中...' : '测试连接',
                    icon: Icons.wifi_tethering_rounded,
                    compact: true,
                    onPressed: syncState.isTesting || syncState.isBusy
                        ? null
                        : _handleTestConnection,
                  ),
                  KonataPillButton.primary(
                    key: const ValueKey('settings_webdav_sync_now'),
                    label: syncState.isBusy ? '同步中...' : '立即同步',
                    icon: Icons.sync_rounded,
                    compact: true,
                    onPressed:
                        syncState.isBusy ||
                            syncState.isTesting ||
                            !syncState.config.syncScope.hasAnySelected
                        ? null
                        : _handleSyncNow,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                syncState.lastError ?? _testResultText ?? lastSyncText,
                style: TextStyle(
                  color:
                      (syncState.lastError != null ||
                          (_testResultText != null && _testResultIsError))
                      ? p.danger
                      : p.textSecondary,
                  fontSize: KonataTheme.fontSizeBodyXs,
                ),
              ),
            ],
          ),
        ),
        if (widget.extraSection != null) ...[
          const SizedBox(height: 16),
          widget.extraSection!,
        ],
      ],
    );
  }

  Widget _buildPeriodicIntervalRow(KonataPalette p, WebDavSyncConfig config) {
    final currentMinutes = WebDavSyncConfig.normalizeIntervalMinutes(
      config.autoSyncIntervalMinutes,
    );
    final options = <KonataDropdownOption<int>>[
      for (final m in WebDavSyncConfig.allowedAutoSyncIntervalsMinutes)
        KonataDropdownOption<int>(
          value: m,
          label: WebDavSyncConfig.formatIntervalLabel(m),
        ),
      if (!WebDavSyncConfig.allowedAutoSyncIntervalsMinutes.contains(
        currentMinutes,
      ))
        KonataDropdownOption<int>(
          value: currentMinutes,
          label: WebDavSyncConfig.formatIntervalLabel(currentMinutes),
        ),
    ];
    final dropdown = KonataDropdown<int>(
      key: const ValueKey('settings_webdav_sync_interval'),
      value: currentMinutes,
      dense: true,
      options: options,
      onChanged: (nextMinutes) {
        _hasPendingSave = false;
        ref
            .read(webDavSyncControllerProvider.notifier)
            .saveConfig(
              _draftConfig(
                config,
              ).copyWith(autoSyncIntervalMinutes: nextMinutes),
            );
      },
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final labelBlock = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '定时自动同步间隔',
              style: TextStyle(
                color: p.textPrimary,
                fontSize: KonataTheme.fontSizeBodySm,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '开启 WebDAV 同步后按设定周期在后台静默双向同步',
              style: TextStyle(
                color: p.textMuted,
                fontSize: KonataTheme.fontSizeBodyXs,
              ),
            ),
          ],
        );
        if (constraints.maxWidth < 420) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              labelBlock,
              const SizedBox(height: 8),
              dropdown,
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: labelBlock),
            const SizedBox(width: 12),
            SizedBox(width: 224, child: dropdown),
          ],
        );
      },
    );
  }
}

/// 备份导出、备份恢复与 WebDAV 同步共用的三类数据范围勾选列表（避免三处重复手写开关）。
class _SyncDataScopeSwitches extends StatelessWidget {
  const _SyncDataScopeSwitches({
    required this.keyPrefix,
    required this.scope,
    required this.onChanged,
    this.preview,
    this.disableWhenEmpty = false,
  });

  final String keyPrefix;
  final KonataSyncDataScope scope;
  final ValueChanged<KonataSyncDataScope> onChanged;
  final KonataBackupPreview? preview;
  final bool disableWhenEmpty;

  @override
  Widget build(BuildContext context) {
    final playbacksCount = preview?.playbackCount;
    final matchedPlaybacks = preview?.matchedPlaybackCount;
    final tombstonesCount = preview?.tombstoneCount ?? 0;
    final hasCatalog = preview?.hasLibraryCatalog == true;
    final catalogWorkCount = preview?.catalogWorkCount ?? 0;
    final catalogSourceCount = preview?.catalogSourceCount ?? 0;
    final overridesCount = preview?.workOverrideCount;
    final matchedOverrides = preview?.matchedWorkOverrideCount;
    final prefsCount = preview?.preferenceCount;

    final playbacksAvailable =
        !disableWhenEmpty ||
        preview == null ||
        (playbacksCount ?? 0) > 0 ||
        tombstonesCount > 0;
    final overridesAvailable =
        !disableWhenEmpty ||
        preview == null ||
        hasCatalog ||
        (overridesCount ?? 0) > 0;
    final prefsAvailable =
        !disableWhenEmpty || preview == null || (prefsCount ?? 0) > 0;

    final playbacksLabel = playbacksCount == null
        ? '观看进度与播放历史'
        : (!hasCatalog && matchedPlaybacks != null)
        ? '观看进度与播放历史（$playbacksCount 条，本机匹配 $matchedPlaybacks 条）'
        : '观看进度与播放历史（$playbacksCount 条）';
    final libraryLabel = preview == null
        ? '整理好的媒体库'
        : hasCatalog
        ? '整理好的媒体库（$catalogWorkCount 部作品 · $catalogSourceCount 个媒体源）'
        : matchedOverrides != null
        ? '作品整理与隐藏状态（$overridesCount 项，本机匹配 $matchedOverrides 项）'
        : '整理好的媒体库（$overridesCount 项）';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        KonataSettingsSwitchRow(
          key: ValueKey('${keyPrefix}_playbacks'),
          label: playbacksLabel,
          subtitle: '包含各集播放位置、已看状态与跨端删除记录',
          value: scope.includePlaybacks && playbacksAvailable,
          enabled: playbacksAvailable,
          onChanged: (v) => onChanged(scope.copyWith(includePlaybacks: v)),
        ),
        const SizedBox(height: 10),
        KonataSettingsSwitchRow(
          key: ValueKey('${keyPrefix}_work_overrides'),
          label: libraryLabel,
          subtitle: '包含已整理作品元数据、剧集特典、文件映射、系列编组、隐藏锁定与媒体源结构（不含密码）',
          value: scope.includeWorkOverrides && overridesAvailable,
          enabled: overridesAvailable,
          onChanged: (v) => onChanged(scope.copyWith(includeWorkOverrides: v)),
        ),
        const SizedBox(height: 10),
        KonataSettingsSwitchRow(
          key: ValueKey('${keyPrefix}_preferences'),
          label: prefsCount == null
              ? '便携偏好设置'
              : '便携偏好设置（$prefsCount 项）',
          subtitle: '包含外观主题、详情页显示、播放器与网络镜像偏好（不含密码与密钥）',
          value: scope.includePreferences && prefsAvailable,
          enabled: prefsAvailable,
          onChanged: (v) => onChanged(scope.copyWith(includePreferences: v)),
        ),
      ],
    );
  }
}
