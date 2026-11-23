import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../application/providers/sync_providers.dart';
import '../../domain/formatting/network_error_sanitizer.dart';
import '../../domain/sync/konata_sync_models.dart';
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
    var scope = KonataSyncDataScope(
      includePlaybacks: preview.playbackCount > 0 || preview.tombstoneCount > 0,
      includeWorkOverrides: preview.workOverrideCount > 0,
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
                  '自由勾选需要写入 .konata 备份文件的数据分类（始终自动剥离密码与 API 密钥，附带 SHA-256 完整性校验）。',
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
        allowedExtensions: const <String>['konata', 'json'],
        allowMultiple: false,
      );
      if (picked.isEmpty || !mounted) return;
      final file = picked.first;
      final bytes = await file.readAsBytes();
      final preview = ref
          .read(konataBackupServiceProvider)
          .inspectKonataArchiveBytes(bytes);
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
        showKonataToast(context, '恢复完成：${outcome.toSummaryMessage()}');
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
    var scope = KonataSyncDataScope(
      includePlaybacks: preview.playbackCount > 0 || preview.tombstoneCount > 0,
      includeWorkOverrides: preview.workOverrideCount > 0,
      includePreferences: preview.preferenceCount > 0,
    );
    return showKonataGlassDialog<
      ({KonataBackupRestoreMode mode, KonataSyncDataScope scope})
    >(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final p = ctx.palette;
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
                if (scope.includePlaybacks) ...[
                  const SizedBox(height: 16),
                  Text(
                    '进度恢复策略',
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
                        label: '覆盖播放记录',
                      ),
                    ],
                    onChanged: (next) => setDialogState(() => mode = next),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    mode == KonataBackupRestoreMode.smartMerge
                        ? '保留两端观看进度并取最新位置，任一端已看状态自动保留。'
                        : '先清空当前设备播放历史，再按备份快照重建（不删除媒体源与文件）。',
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
        showKonataToast(context, '多设备同步完成：${outcome.toSummaryMessage()}');
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
                subtitle: '可自选观看进度、作品整理状态与便携偏好导出（自动剥离密码与密钥，带 SHA-256 校验）',
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
                subtitle: '导入前校验完整性并预览各项条目数，支持自选恢复内容与智能合并/覆盖策略，绝不触碰物理媒体文件',
                leading: _buildLeadingBox(p, Icons.unarchive_outlined),
                trailing: Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: p.textMuted,
                ),
                onTap: _restoringBackup ? null : _importBackup,
              ),
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
                          '每台设备独立写入专属分片，跨 Windows 与 Android 零锁冲突同步观看进度与整理状态',
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
    final tombstonesCount = preview?.tombstoneCount ?? 0;
    final overridesCount = preview?.workOverrideCount;
    final prefsCount = preview?.preferenceCount;

    final playbacksAvailable =
        !disableWhenEmpty ||
        preview == null ||
        (playbacksCount ?? 0) > 0 ||
        tombstonesCount > 0;
    final overridesAvailable =
        !disableWhenEmpty || preview == null || (overridesCount ?? 0) > 0;
    final prefsAvailable =
        !disableWhenEmpty || preview == null || (prefsCount ?? 0) > 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        KonataSettingsSwitchRow(
          key: ValueKey('${keyPrefix}_playbacks'),
          label: playbacksCount == null
              ? '观看进度与播放历史'
              : '观看进度与播放历史（$playbacksCount 条）',
          subtitle: '包含各集播放位置、已看状态与跨端删除记录',
          value: scope.includePlaybacks && playbacksAvailable,
          enabled: playbacksAvailable,
          onChanged: (v) => onChanged(scope.copyWith(includePlaybacks: v)),
        ),
        const SizedBox(height: 10),
        KonataSettingsSwitchRow(
          key: ValueKey('${keyPrefix}_work_overrides'),
          label: overridesCount == null
              ? '作品整理与隐藏状态'
              : '作品整理与隐藏状态（$overridesCount 项）',
          subtitle: '包含人工匹配锁定、隐藏/永久隐藏状态与系列排序标签',
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
