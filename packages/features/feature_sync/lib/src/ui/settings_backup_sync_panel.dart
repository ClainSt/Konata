import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/sync_models.dart';
import '../providers.dart';
import '../state/sync_backup_controller.dart';

/// 设置页“备份与同步”功能面板（仅依赖基础 UI 与 `konata_design_system`，零默认组件库导入）。
class SettingsBackupSyncPanel extends ConsumerStatefulWidget {
  /// 创建备份与同步设置面板。
  const SettingsBackupSyncPanel({
    super.key,
    this.controllerOverride,
    this.embedded = false,
  });

  /// 可选注入控制器实例（主要用于离线组件测试跳过容器依赖）。
  final SyncBackupController? controllerOverride;

  /// 是否嵌入外部已带纵向滚动条的设置页容器中。
  final bool embedded;

  @override
  ConsumerState<SettingsBackupSyncPanel> createState() =>
      _SettingsBackupSyncPanelState();
}

class _SettingsBackupSyncPanelState
    extends ConsumerState<SettingsBackupSyncPanel> {
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _remoteDirController = TextEditingController();
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  SyncBackupController? _boundController;
  bool _formHydrated = false;
  bool _obscurePassword = true;
  bool _autoSyncOnStartup = false;
  bool _autoSyncOnPlaybackStop = false;
  bool _webDavEnabled = false;
  int _autoSyncIntervalMinutes = 0;
  Set<String>? _webDavSliceIds;

  SyncBackupController _resolveController({bool listen = false}) {
    final override = widget.controllerOverride;
    if (override != null) {
      return override;
    }
    return listen
        ? ref.watch(syncBackupControllerProvider)
        : ref.read(syncBackupControllerProvider);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncControllerBinding();
  }

  @override
  void didUpdateWidget(covariant SettingsBackupSyncPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controllerOverride != widget.controllerOverride) {
      _formHydrated = false;
      _syncControllerBinding();
    }
  }

  void _syncControllerBinding() {
    final next = _resolveController();
    if (identical(_boundController, next)) {
      _hydrateWebDavFormIfNeeded(next.state);
      return;
    }
    _boundController?.removeListener(_handleControllerChanged);
    _boundController = next;
    next.addListener(_handleControllerChanged);
    _hydrateWebDavFormIfNeeded(next.state);
  }

  void _handleControllerChanged() {
    final controller = _boundController;
    if (controller == null || !mounted) return;
    _hydrateWebDavFormIfNeeded(controller.state);
  }

  void _hydrateWebDavFormIfNeeded(SyncBackupState state) {
    if (_formHydrated || !state.isInitialized) return;
    final cfg = state.webDavConfig;
    _urlController.text = cfg.baseUrl;
    _remoteDirController.text = cfg.remoteDir;
    _usernameController.text = cfg.username;
    _passwordController.text = cfg.password;
    _webDavEnabled = cfg.enabled;
    _autoSyncOnStartup = cfg.autoSyncOnStartup;
    _autoSyncOnPlaybackStop = cfg.autoSyncOnPlaybackStop;
    _autoSyncIntervalMinutes = cfg.autoSyncIntervalMinutes;
    _webDavSliceIds = cfg.selectedSliceIds == null
        ? null
        : Set<String>.of(cfg.selectedSliceIds!);
    _formHydrated = true;
  }

  WebDavSyncConfig _buildDraftConfig(SyncBackupState state) {
    final allSliceIds = <String>{
      for (final item in state.availableSlices) item.sliceId,
    };
    final effectiveSelected = _webDavSliceIds?.where(allSliceIds.contains).toSet();
    return WebDavSyncConfig(
      enabled: _webDavEnabled,
      baseUrl: _urlController.text.trim(),
      remoteDir: _remoteDirController.text.trim().isEmpty
          ? WebDavSyncConfig.defaultRemoteDir
          : _remoteDirController.text.trim(),
      username: _usernameController.text.trim(),
      password: _passwordController.text,
      autoSyncOnStartup: _autoSyncOnStartup,
      autoSyncOnPlaybackStop: _autoSyncOnPlaybackStop,
      autoSyncIntervalMinutes: _autoSyncIntervalMinutes,
      selectedSliceIds: effectiveSelected,
    );
  }

  @override
  void dispose() {
    _boundController?.removeListener(_handleControllerChanged);
    _urlController.dispose();
    _remoteDirController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _resolveController(listen: true);

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final state = controller.state;
        _hydrateWebDavFormIfNeeded(state);
        final palette = context.palette;

        final content = Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _buildLocalBackupCard(context, controller, state, palette),
              const SizedBox(height: 16),
              _buildWebDavSyncCard(context, controller, state, palette),
            ],
          ),
        );

        if (widget.embedded) {
          return content;
        }
        return SingleChildScrollView(child: content);
      },
    );
  }

  Widget _buildLocalBackupCard(
    BuildContext context,
    SyncBackupController controller,
    SyncBackupState state,
    KonataPalette palette,
  ) {
    final selectedCount = state.exportSelectedSliceIds.length;
    final totalCount = state.availableSlices.length;

    return KonataSurfaceCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _SectionTitleRow(
            icon: Icons.cloud_download_outlined,
            title: '本地 .konata 归档备份与恢复',
            subtitle: '按切片选择性导出自校验归档，恢复前先干跑预览新增、更新与删除计数',
            palette: palette,
          ),
          const SizedBox(height: 14),
          if (state.deviceId.isNotEmpty) ...<Widget>[
            _StatusInfoPill(
              icon: Icons.devices_outlined,
              label: '本机设备：${state.deviceName}（ID: ${state.deviceId}）',
              palette: palette,
            ),
            const SizedBox(height: 10),
          ],
          if (state.lastLocalBackupAtMs != null) ...<Widget>[
            _StatusInfoPill(
              icon: Icons.history_outlined,
              label:
                  '最近备份操作：${_formatTimestamp(state.lastLocalBackupAtMs!)}'
                  '${state.lastLocalBackupSummary != null ? ' · ${state.lastLocalBackupSummary}' : ''}',
              palette: palette,
            ),
            const SizedBox(height: 12),
          ],
          _SliceCheckWrap(
            title: '导出包含的数据切片（已选 $selectedCount / $totalCount）',
            slices: state.availableSlices,
            selectedIds: state.exportSelectedSliceIds,
            keyPrefix: 'export_slice',
            onToggle: state.isBusy
                ? null
                : (sliceId, selected) {
                    controller.toggleExportSlice(sliceId, selected);
                  },
            palette: palette,
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: <Widget>[
              KonataPillButton.primary(
                key: const Key('export_konata_button'),
                label: state.isExporting ? '正在导出...' : '导出 .konata 备份',
                icon: Icons.upload_file_outlined,
                onPressed: state.isBusy
                    ? null
                    : () => _handleExportPressed(context, controller),
              ),
              KonataPillButton.secondary(
                key: const Key('import_konata_button'),
                label: state.isPreparingImport ? '正在解析预览...' : '导入并预览恢复',
                icon: Icons.file_open_outlined,
                onPressed: state.isBusy
                    ? null
                    : () => _handleImportPressed(context, controller),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildWebDavSyncCard(
    BuildContext context,
    SyncBackupController controller,
    SyncBackupState state,
    KonataPalette palette,
  ) {
    final activeWebDavSliceIds = _webDavSliceIds == null
        ? state.availableSlices.map((s) => s.sliceId).toSet()
        : _webDavSliceIds!;
    final successColor = palette.isDark
        ? const Color(0xFF4ADE80)
        : const Color(0xFF15803D);
    final dangerColor = palette.isDark
        ? const Color(0xFFF87171)
        : const Color(0xFFB91C1C);

    return KonataSurfaceCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _SectionTitleRow(
            icon: Icons.sync_outlined,
            title: 'WebDAV 多设备分片同步',
            subtitle:
                '基于 manifest.json 与 slices/*.json.gz 增量校验同步；登录密码仅加密保存在系统安全存储中',
            palette: palette,
          ),
          const SizedBox(height: 14),
          _SettingsSwitchRow(
            switchKey: const Key('webdav_enabled_switch'),
            title: '启用 WebDAV 多设备同步',
            subtitle: '开启后支持一键同步与自动策略调度',
            value: _webDavEnabled,
            onChanged: state.isBusy
                ? null
                : (value) => setState(() => _webDavEnabled = value),
            palette: palette,
          ),
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (context, constraints) {
              final narrow = constraints.maxWidth < 520;
              final urlField = AbsorbPointer(
                absorbing: state.isBusy,
                child: KonataSoftTextField(
                  key: const Key('webdav_url_field'),
                  controller: _urlController,
                  label: '服务器地址',
                  hintText: 'https://dav.example.com/dav',
                  prefixIcon: Icons.link_rounded,
                ),
              );
              final dirField = AbsorbPointer(
                absorbing: state.isBusy,
                child: KonataSoftTextField(
                  key: const Key('webdav_remote_dir_field'),
                  controller: _remoteDirController,
                  label: '远端同步目录',
                  hintText: WebDavSyncConfig.defaultRemoteDir,
                  prefixIcon: Icons.folder_outlined,
                ),
              );
              final userField = AbsorbPointer(
                absorbing: state.isBusy,
                child: KonataSoftTextField(
                  key: const Key('webdav_username_field'),
                  controller: _usernameController,
                  label: '用户名',
                  hintText: '可选账号',
                  prefixIcon: Icons.person_outline_rounded,
                ),
              );
              final pwdRow = Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  Expanded(
                    child: AbsorbPointer(
                      absorbing: state.isBusy,
                      child: KonataSoftTextField(
                        key: const Key('webdav_password_field'),
                        controller: _passwordController,
                        label: '应用密码（仅存系统安全存储）',
                        hintText: '不会写入数据库或任何导出切片',
                        prefixIcon: Icons.lock_outline_rounded,
                        obscureText: _obscurePassword,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    key: const Key('webdav_toggle_password_visibility'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setState(
                      () => _obscurePassword = !_obscurePassword,
                    ),
                    child: Container(
                      height: 40,
                      width: 40,
                      decoration: BoxDecoration(
                        color: palette.softFill,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: palette.hairline),
                      ),
                      alignment: Alignment.center,
                      child: Icon(
                        _obscurePassword
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                        size: 18,
                        color: palette.textSecondary,
                      ),
                    ),
                  ),
                ],
              );

              if (narrow) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    urlField,
                    const SizedBox(height: 12),
                    dirField,
                    const SizedBox(height: 12),
                    userField,
                    const SizedBox(height: 12),
                    pwdRow,
                  ],
                );
              }
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Expanded(flex: 3, child: urlField),
                      const SizedBox(width: 12),
                      Expanded(flex: 2, child: dirField),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: <Widget>[
                      Expanded(child: userField),
                      const SizedBox(width: 12),
                      Expanded(child: pwdRow),
                    ],
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 16),
          _SliceCheckWrap(
            title: '参与云端双向协同的切片',
            slices: state.availableSlices,
            selectedIds: activeWebDavSliceIds,
            keyPrefix: 'webdav_slice',
            onToggle: state.isBusy
                ? null
                : (sliceId, selected) {
                    setState(() {
                      final next = Set<String>.of(activeWebDavSliceIds);
                      if (selected) {
                        next.add(sliceId);
                      } else {
                        next.remove(sliceId);
                      }
                      _webDavSliceIds = next;
                    });
                  },
            palette: palette,
          ),
          const SizedBox(height: 14),
          _SettingsSwitchRow(
            switchKey: const Key('webdav_startup_sync_switch'),
            title: '启动时自动同步',
            subtitle: '应用打开完成初始化后静默拉取并合流远端切片变更',
            value: _autoSyncOnStartup,
            onChanged: state.isBusy
                ? null
                : (value) => setState(() => _autoSyncOnStartup = value),
            palette: palette,
          ),
          const SizedBox(height: 10),
          _SettingsSwitchRow(
            switchKey: const Key('webdav_stop_playback_sync_switch'),
            title: '停播后自动上传',
            subtitle: '播放停止并完成防抖后静默同步本机观看进度',
            value: _autoSyncOnPlaybackStop,
            onChanged: state.isBusy
                ? null
                : (value) => setState(() => _autoSyncOnPlaybackStop = value),
            palette: palette,
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final narrow = constraints.maxWidth < 460;
              final label = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    '后台定时同步周期',
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: palette.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '按固定分钟间隔检查远端 manifest.json 的 SHA-256 指纹',
                    style: TextStyle(fontSize: 12, color: palette.textSecondary),
                  ),
                ],
              );
              final dropdown = KonataDropdown<int>(
                key: const Key('webdav_interval_dropdown'),
                value: _autoSyncIntervalMinutes,
                options: <KonataDropdownOption<int>>[
                  for (final minutes
                      in WebDavSyncConfig.allowedAutoSyncIntervalsMinutes)
                    KonataDropdownOption<int>(
                      value: minutes,
                      label: WebDavSyncConfig.formatIntervalLabel(minutes),
                    ),
                ],
                onChanged: state.isBusy
                    ? null
                    : (value) => setState(() => _autoSyncIntervalMinutes = value),
              );
              if (narrow) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[label, const SizedBox(height: 8), dropdown],
                );
              }
              return Row(
                children: <Widget>[
                  Expanded(child: label),
                  const SizedBox(width: 12),
                  SizedBox(width: 230, child: dropdown),
                ],
              );
            },
          ),
          if (state.webDavTestSuccessMessage != null) ...<Widget>[
            const SizedBox(height: 12),
            _StatusInfoPill(
              icon: Icons.check_circle_outline,
              label: state.webDavTestSuccessMessage!,
              palette: palette,
              accentColor: successColor,
            ),
          ],
          if (state.lastErrorMessage != null) ...<Widget>[
            const SizedBox(height: 12),
            _StatusInfoPill(
              icon: Icons.error_outline,
              label: state.lastErrorMessage!,
              palette: palette,
              accentColor: dangerColor,
            ),
          ],
          if (state.lastWebDavSyncAtMs != null) ...<Widget>[
            const SizedBox(height: 12),
            _StatusInfoPill(
              icon: Icons.cloud_done_outlined,
              label:
                  '最近云端同步：${_formatTimestamp(state.lastWebDavSyncAtMs!)}'
                  '${state.lastWebDavSyncSummary != null ? ' · ${state.lastWebDavSyncSummary}' : ''}',
              palette: palette,
            ),
          ],
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: <Widget>[
              KonataPillButton.secondary(
                key: const Key('webdav_test_button'),
                label: state.isTestingWebDav ? '正在测试...' : '测试连接',
                icon: Icons.wifi_tethering_outlined,
                onPressed: state.isBusy
                    ? null
                    : () => _handleTestWebDavPressed(
                        context,
                        controller,
                        state,
                      ),
              ),
              KonataPillButton.secondary(
                key: const Key('webdav_save_button'),
                label: '保存配置',
                icon: Icons.save_outlined,
                onPressed: state.isBusy
                    ? null
                    : () => _handleSaveWebDavPressed(
                        context,
                        controller,
                        state,
                      ),
              ),
              KonataPillButton.primary(
                key: const Key('webdav_sync_now_button'),
                label: state.isSyncingWebDav ? '正在同步...' : '立即双向同步',
                icon: Icons.sync,
                onPressed: state.isBusy
                    ? null
                    : () => _handleSyncNowPressed(context, controller, state),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _handleExportPressed(
    BuildContext context,
    SyncBackupController controller,
  ) async {
    if (controller.state.exportSelectedSliceIds.isEmpty) {
      showKonataToast(context, '请至少勾选一个要导出的同步切片', isError: true);
      return;
    }
    try {
      final savedPath = await controller.exportBackupToFilePort();
      if (!context.mounted || savedPath == null) return;
      showKonataToast(context, '备份导出成功：$savedPath');
    } catch (_) {
      if (!context.mounted) return;
      showKonataToast(
        context,
        controller.state.lastErrorMessage ?? '导出备份失败',
        isError: true,
      );
    }
  }

  Future<void> _handleImportPressed(
    BuildContext context,
    SyncBackupController controller,
  ) async {
    PickedBackupArchiveData? picked;
    try {
      picked = await controller.pickAndPreviewBackup();
    } catch (_) {
      if (!context.mounted) return;
      showKonataToast(
        context,
        controller.state.lastErrorMessage ?? '读取备份文件失败',
        isError: true,
      );
      return;
    }
    if (!context.mounted || picked == null) return;

    await showKonataGlassDialog<void>(
      context: context,
      builder: (_) => _RestorePreviewDialog(
        controller: controller,
        initialData: picked!,
      ),
    );
  }

  Future<void> _handleSaveWebDavPressed(
    BuildContext context,
    SyncBackupController controller,
    SyncBackupState state,
  ) async {
    final draft = _buildDraftConfig(state);
    await controller.saveWebDavConfig(draft);
    if (!context.mounted) return;
    showKonataToast(context, 'WebDAV 配置已保存（密码已写入系统安全存储）');
  }

  Future<void> _handleTestWebDavPressed(
    BuildContext context,
    SyncBackupController controller,
    SyncBackupState state,
  ) async {
    final draft = _buildDraftConfig(state);
    try {
      await controller.testWebDavConnection(draft);
      if (!context.mounted) return;
      showKonataToast(context, 'WebDAV 连接测试成功');
    } catch (_) {
      if (!context.mounted) return;
      showKonataToast(
        context,
        controller.state.lastErrorMessage ?? 'WebDAV 连接失败',
        isError: true,
      );
    }
  }

  Future<void> _handleSyncNowPressed(
    BuildContext context,
    SyncBackupController controller,
    SyncBackupState state,
  ) async {
    final draft = _buildDraftConfig(state);
    try {
      final outcome = await controller.syncNow(draftConfig: draft);
      if (!context.mounted || outcome == null) return;
      showKonataToast(context, '同步完成：${outcome.toSummaryMessage()}');
    } catch (_) {
      if (!context.mounted) return;
      showKonataToast(
        context,
        controller.state.lastErrorMessage ?? 'WebDAV 同步失败',
        isError: true,
      );
    }
  }

  static String _formatTimestamp(int timestampMs) {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestampMs);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
  }
}

class _RestorePreviewDialog extends StatefulWidget {
  const _RestorePreviewDialog({
    required this.controller,
    required this.initialData,
  });

  final SyncBackupController controller;
  final PickedBackupArchiveData initialData;

  @override
  State<_RestorePreviewDialog> createState() => _RestorePreviewDialogState();
}

class _RestorePreviewDialogState extends State<_RestorePreviewDialog> {
  late PickedBackupArchiveData _data = widget.initialData;
  late final Set<String> _selectedIds = <String>{
    for (final item in widget.initialData.report.slicePreviews)
      if (item.remoteAvailable) item.sliceId,
  };
  bool _recalculating = false;
  bool _applying = false;

  Future<void> _switchMode(KonataRestoreMode nextMode) async {
    if (_data.mode == nextMode || _recalculating || _applying) return;
    setState(() => _recalculating = true);
    try {
      final updated = await widget.controller.previewBackupBytes(
        _data.bytes,
        fileName: _data.fileName,
        mode: nextMode,
      );
      if (!mounted) return;
      setState(() => _data = updated);
    } finally {
      if (mounted) {
        setState(() => _recalculating = false);
      }
    }
  }

  Future<void> _applyRestore() async {
    if (_selectedIds.isEmpty || _applying || _recalculating) return;
    setState(() => _applying = true);
    try {
      final outcome = await widget.controller.restoreBackupBytes(
        _data.bytes,
        selectedSliceIds: _selectedIds,
        mode: _data.mode,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      showKonataToast(context, '备份恢复完成：${outcome.toSummaryMessage()}');
    } catch (_) {
      if (!mounted) return;
      setState(() => _applying = false);
      showKonataToast(
        context,
        widget.controller.state.lastErrorMessage ?? '恢复失败',
        isError: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final report = _data.report;
    final maxDialogHeight = math.min(
      560.0,
      math.max(260.0, MediaQuery.sizeOf(context).height - 40),
    );

    return KonataGlassDialog(
      title: '备份导入干跑预览确认',
      width: 560,
      maxHeight: maxDialogHeight,
      actions: <Widget>[
        KonataPillButton.ghost(
          key: const Key('restore_preview_cancel_button'),
          label: '取消',
          onPressed: _applying ? null : () => Navigator.of(context).pop(),
        ),
        KonataPillButton.primary(
          key: const Key('restore_preview_confirm_button'),
          label: _applying ? '正在应用...' : '确认应用恢复',
          onPressed: (_selectedIds.isEmpty || _applying || _recalculating)
              ? null
              : _applyRestore,
        ),
      ],
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              '文件：${_data.fileName}\n'
              '来源设备：${report.deviceName}（${report.platform} · 应用 ${report.appVersion}）',
              style: TextStyle(
                fontSize: 12.5,
                height: 1.45,
                color: palette.textSecondary,
              ),
            ),
            const SizedBox(height: 12),
            KonataSegmentedCapsule<KonataRestoreMode>(
              key: const Key('restore_mode_segmented'),
              expand: true,
              compact: true,
              selected: _data.mode,
              options: const <KonataSegmentOption<KonataRestoreMode>>[
                KonataSegmentOption<KonataRestoreMode>(
                  value: KonataRestoreMode.smartMerge,
                  label: '智能合并',
                ),
                KonataSegmentOption<KonataRestoreMode>(
                  value: KonataRestoreMode.overwrite,
                  label: '覆盖还原',
                ),
              ],
              onChanged: _applying ? (_) {} : _switchMode,
            ),
            const SizedBox(height: 12),
            Text(
              _recalculating
                  ? '正在重新计算干跑合并差异...'
                  : '预计累计变更：新增 ${report.totalInserts} 项 · 更新 ${report.totalUpdates} 项 · 删除 ${report.totalDeletes} 项',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: palette.textPrimary,
              ),
            ),
            const SizedBox(height: 10),
            for (final preview in report.slicePreviews) ...<Widget>[
              _PreviewSliceRow(
                preview: preview,
                selected: _selectedIds.contains(preview.sliceId),
                onChanged: (!preview.remoteAvailable || _applying)
                    ? null
                    : (checked) {
                        setState(() {
                          if (checked) {
                            _selectedIds.add(preview.sliceId);
                          } else {
                            _selectedIds.remove(preview.sliceId);
                          }
                        });
                      },
                palette: palette,
              ),
              const SizedBox(height: 8),
            ],
            if (report.unrecognizedSliceIds.isNotEmpty) ...<Widget>[
              Text(
                '注：以下外部切片未在当前模块中注册，将自动跳过：${report.unrecognizedSliceIds.join('、')}',
                style: TextStyle(fontSize: 11.5, color: palette.textMuted),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PreviewSliceRow extends StatelessWidget {
  const _PreviewSliceRow({
    required this.preview,
    required this.selected,
    required this.onChanged,
    required this.palette,
  });

  final KonataSlicePreview preview;
  final bool selected;
  final ValueChanged<bool>? onChanged;
  final KonataPalette palette;

  @override
  Widget build(BuildContext context) {
    final summary = preview.remoteAvailable
        ? '新增 ${preview.insertCount} · 更新 ${preview.updateCount} · 删除 ${preview.deleteCount} · 跳过 ${preview.skippedCount}'
        : '备份归档中未包含该切片';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: palette.softFill,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: palette.hairline),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  preview.displayName,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: preview.remoteAvailable
                        ? palette.textPrimary
                        : palette.textMuted,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  summary,
                  style: TextStyle(fontSize: 12, color: palette.textSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          KonataSwitch(
            key: Key('preview_slice_${preview.sliceId}'),
            value: preview.remoteAvailable && selected,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

class _SectionTitleRow extends StatelessWidget {
  const _SectionTitleRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.palette,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final KonataPalette palette;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: palette.accent.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(10),
          ),
          alignment: Alignment.center,
          child: Icon(icon, size: 20, color: palette.accent),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                title,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: palette.textPrimary,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                subtitle,
                style: TextStyle(fontSize: 12.5, color: palette.textSecondary),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SettingsSwitchRow extends StatelessWidget {
  const _SettingsSwitchRow({
    required this.switchKey,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    required this.palette,
  });

  final Key switchKey;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final KonataPalette palette;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                title,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: palette.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(fontSize: 12, color: palette.textSecondary),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        KonataSwitch(key: switchKey, value: value, onChanged: onChanged),
      ],
    );
  }
}

class _SliceCheckWrap extends StatelessWidget {
  const _SliceCheckWrap({
    required this.title,
    required this.slices,
    required this.selectedIds,
    required this.keyPrefix,
    required this.onToggle,
    required this.palette,
  });

  final String title;
  final List<SyncSliceInfo> slices;
  final Set<String> selectedIds;
  final String keyPrefix;
  final void Function(String sliceId, bool selected)? onToggle;
  final KonataPalette palette;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          title,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: palette.textPrimary,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          children: <Widget>[
            for (final slice in slices)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: palette.softFill,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: palette.hairline),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      slice.displayName,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: palette.textPrimary,
                      ),
                    ),
                    const SizedBox(width: 8),
                    KonataSwitch(
                      key: Key('${keyPrefix}_${slice.sliceId}'),
                      value: selectedIds.contains(slice.sliceId),
                      onChanged: onToggle == null
                          ? null
                          : (checked) => onToggle!(slice.sliceId, checked),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _StatusInfoPill extends StatelessWidget {
  const _StatusInfoPill({
    required this.icon,
    required this.label,
    required this.palette,
    this.accentColor,
  });

  final IconData icon;
  final String label;
  final KonataPalette palette;
  final Color? accentColor;

  @override
  Widget build(BuildContext context) {
    final tint = accentColor ?? palette.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: (accentColor ?? palette.hairline).withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: (accentColor ?? palette.hairline).withValues(alpha: 0.42),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 16, color: tint),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: TextStyle(fontSize: 12.5, color: palette.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}
