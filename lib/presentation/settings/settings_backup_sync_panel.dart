import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../application/providers/sync_providers.dart';
import '../../domain/formatting/network_error_sanitizer.dart';
import '../../domain/sync/konata_sync_models.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/konata_glass_dialog.dart';
import '../widgets/design_system/konata_pill_button.dart';
import '../widgets/design_system/konata_segmented_capsule.dart';
import '../widgets/design_system/konata_soft_text_field.dart';
import '../widgets/design_system/konata_surface_card.dart';
import '../widgets/design_system/konata_switch.dart';
import '../widgets/design_system/konata_system_file_picker.dart';
import '../widgets/design_system/konata_toast.dart';

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
  Timer? _autoSaveTimer;
  String? _testResultText;
  bool _testResultIsError = false;

  @override
  void dispose() {
    _autoSaveTimer?.cancel();
    _urlController.dispose();
    _dirController.dispose();
    _userController.dispose();
    _passController.dispose();
    super.dispose();
  }

  void _syncControllersIfNeeded(WebDavSyncUiState syncState) {
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
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(KonataTheme.settingsAutoSaveDebounce, () {
      if (!mounted) return;
      final current = ref.read(webDavSyncControllerProvider).config;
      unawaited(
        ref
            .read(webDavSyncControllerProvider.notifier)
            .saveConfig(_draftConfig(current)),
      );
    });
  }

  String _formatDateTime(DateTime dt) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}.${two(dt.month)}.${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}';
  }

  String _timestampSuffix() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
  }

  Future<void> _exportBackup() async {
    if (_exportingBackup) return;
    setState(() => _exportingBackup = true);
    try {
      final bytes = await ref
          .read(konataBackupServiceProvider)
          .exportKonataArchiveBytes();
      final uri = await ref.read(konataSystemFilePickerProvider).saveFile(
        dialogTitle: '导出 Konata 本地备份',
        fileName: 'konata_backup_${_timestampSuffix()}.konata',
        bytes: bytes,
      );
      if (uri == null || !mounted) return;
      final pathText = uri.isScheme('file') ? uri.toFilePath() : uri.toString();
      showKonataToast(context, '已导出备份至 $pathText');
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

      final selectedMode = await _showRestoreConfirmDialog(preview);
      if (selectedMode == null || !mounted) return;

      final outcome = await ref
          .read(webDavSyncControllerProvider.notifier)
          .restoreLocalBackup(bytes, mode: selectedMode);
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

  Future<KonataBackupRestoreMode?> _showRestoreConfirmDialog(
    KonataBackupPreview preview,
  ) {
    var mode = KonataBackupRestoreMode.smartMerge;
    return showKonataGlassDialog<KonataBackupRestoreMode>(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final p = ctx.palette;
          return KonataGlassDialog(
            title: '确认恢复本地备份',
            width: 480,
            actions: [
              KonataPillButton.ghost(
                label: '取消',
                onPressed: () => Navigator.of(dialogCtx).pop(),
              ),
              KonataPillButton.primary(
                label: '开始恢复',
                onPressed: () => Navigator.of(dialogCtx).pop(mode),
              ),
            ],
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '来源：${preview.deviceName} · ${_formatDateTime(preview.exportedAt)}',
                  style: TextStyle(
                    color: p.textMuted,
                    fontSize: KonataTheme.fontSizeBodyXs,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '已通过 SHA-256 完整性校验，备份包含 ${preview.playbackCount} 条观看进度、'
                  '${preview.workOverrideCount} 项作品整理记录与 ${preview.preferenceCount} 项偏好设置'
                  '（不含任何密码或密钥，不修改本地物理文件）。',
                  style: TextStyle(
                    color: p.textSecondary,
                    fontSize: KonataTheme.fontSizeBodySm,
                    height: 1.5,
                  ),
                ),
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

  Widget _buildLeadingBox(KonataPalette p, IconData icon) {
    return SizedBox(
      width: 38,
      height: 38,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: p.softFill,
          borderRadius: KonataTheme.borderRadiusControl,
          border: Border.all(color: p.hairline, width: 1),
        ),
        child: Center(child: Icon(icon, size: 20, color: p.textSecondary)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final syncState = ref.watch(webDavSyncControllerProvider);
    _syncControllersIfNeeded(syncState);

    final lastSyncText = syncState.lastSyncAt == null
        ? '尚未同步'
        : '上次同步：${_formatDateTime(syncState.lastSyncAt!)}'
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
                subtitle: '打包全部观看进度、作品整理锁、隐藏状态与便携偏好（自动剥离密码与密钥，带 SHA-256 校验）',
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
                subtitle: '导入前先校验完整性并预览条目数，支持智能合并或覆盖还原，绝不触碰物理媒体文件',
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
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '启动时自动同步',
                      style: TextStyle(
                        color: p.textPrimary,
                        fontSize: KonataTheme.fontSizeBodySm,
                      ),
                    ),
                  ),
                  KonataSwitch(
                    value: syncState.config.autoSyncOnStartup,
                    onChanged: (value) => ref
                        .read(webDavSyncControllerProvider.notifier)
                        .saveConfig(
                          _draftConfig(
                            syncState.config,
                          ).copyWith(autoSyncOnStartup: value),
                        ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '停播后静默上传进度',
                      style: TextStyle(
                        color: p.textPrimary,
                        fontSize: KonataTheme.fontSizeBodySm,
                      ),
                    ),
                  ),
                  KonataSwitch(
                    value: syncState.config.autoSyncOnPlaybackStop,
                    onChanged: (value) => ref
                        .read(webDavSyncControllerProvider.notifier)
                        .saveConfig(
                          _draftConfig(
                            syncState.config,
                          ).copyWith(autoSyncOnPlaybackStop: value),
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
                    onPressed: syncState.isBusy || syncState.isTesting
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
}
