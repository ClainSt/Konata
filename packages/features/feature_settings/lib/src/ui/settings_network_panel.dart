import 'dart:async';

import 'package:engine_sources/engine_sources.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../providers.dart';
import '../state/settings_controller.dart';
import 'fanart_api_help_dialog.dart';
import 'tmdb_api_help_dialog.dart';

/// 刮削与网络设置面板（官方优先 + 备用地址自动回退 + 即时自动持久化 + 多通道独立连通性测试）。
class SettingsNetworkPanel extends ConsumerStatefulWidget {
  /// 创建刮削与网络设置面板。
  const SettingsNetworkPanel({super.key, this.controller});

  /// 可选直传设置控制器；为空时从 [settingsControllerProvider] 获取。
  final SettingsController? controller;

  @override
  ConsumerState<SettingsNetworkPanel> createState() =>
      _SettingsNetworkPanelState();
}

class _SettingsNetworkPanelState extends ConsumerState<SettingsNetworkPanel> {
  final TextEditingController _credentialController = TextEditingController();
  final TextEditingController _tmdbApiBackupController =
      TextEditingController();
  final TextEditingController _tmdbImageBackupController =
      TextEditingController();
  final TextEditingController _bgmApiBackupController = TextEditingController();
  final TextEditingController _bgmImageBackupController =
      TextEditingController();
  final TextEditingController _fanartClientKeyController =
      TextEditingController();
  final TextEditingController _fanartApiKeyOverrideController =
      TextEditingController();
  final TextEditingController _fanartApiBackupController =
      TextEditingController();
  final TextEditingController _fanartImageBackupController =
      TextEditingController();
  final TextEditingController _proxyUrlController = TextEditingController();

  ProxyMode _proxyMode = ProxyMode.system;
  bool _obscureTmdb = true;
  bool _obscureFanart = true;
  bool _fanartAdvancedExpanded = false;
  bool _hasPendingSave = false;
  bool _hydratedOnce = false;
  Timer? _autoSaveTimer;
  SettingsController? _observedController;

  SettingsController get _controller =>
      widget.controller ?? ref.read(settingsControllerProvider);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ctrl = _controller;
    if (!identical(_observedController, ctrl)) {
      _observedController?.removeListener(_onControllerUpdated);
      _observedController = ctrl;
      ctrl.addListener(_onControllerUpdated);
      _syncFieldsFromConfig(ctrl.networkConfig, force: true);
    }
  }

  void _onControllerUpdated() {
    if (!mounted) return;
    final ctrl = _observedController;
    if (ctrl != null &&
        !_hydratedOnce &&
        !ctrl.isLoadingNetwork &&
        !_hasPendingSave) {
      _syncFieldsFromConfig(ctrl.networkConfig, force: true);
    }
  }

  void _syncFieldsFromConfig(KonataNetworkConfig cfg, {required bool force}) {
    if (!force && _hydratedOnce) {
      return;
    }
    _credentialController.text = cfg.credential;
    _tmdbApiBackupController.text = cfg.tmdbBackupApiBase;
    _tmdbImageBackupController.text = cfg.tmdbBackupImageBase;
    _bgmApiBackupController.text = cfg.bangumiBackupApiBase;
    _bgmImageBackupController.text = cfg.bangumiBackupImageBase;
    _fanartClientKeyController.text = cfg.fanartClientKey;
    _fanartApiKeyOverrideController.text = cfg.fanartApiKeyOverride;
    _fanartApiBackupController.text = cfg.fanartBackupApiBase;
    _fanartImageBackupController.text = cfg.fanartBackupImageBase;
    _proxyMode = cfg.proxyMode;
    _proxyUrlController.text = cfg.proxyUrl;
    if (!_controller.isLoadingNetwork) {
      _hydratedOnce = true;
    }
  }

  @override
  void dispose() {
    _autoSaveTimer?.cancel();
    _autoSaveTimer = null;
    final pendingController = _observedController;
    pendingController?.removeListener(_onControllerUpdated);
    if (_hasPendingSave && pendingController != null) {
      _hasPendingSave = false;
      unawaited(pendingController.saveNetworkConfig(_buildNetworkConfig()));
    }
    _credentialController.dispose();
    _tmdbApiBackupController.dispose();
    _tmdbImageBackupController.dispose();
    _bgmApiBackupController.dispose();
    _bgmImageBackupController.dispose();
    _fanartClientKeyController.dispose();
    _fanartApiKeyOverrideController.dispose();
    _fanartApiBackupController.dispose();
    _fanartImageBackupController.dispose();
    _proxyUrlController.dispose();
    super.dispose();
  }

  KonataNetworkConfig _buildNetworkConfig() {
    return KonataNetworkConfig(
      credential: _credentialController.text.trim(),
      tmdbBackupApiBase: _tmdbApiBackupController.text.trim(),
      tmdbBackupImageBase: _tmdbImageBackupController.text.trim(),
      bangumiBackupApiBase: _bgmApiBackupController.text.trim(),
      bangumiBackupImageBase: _bgmImageBackupController.text.trim(),
      fanartClientKey: _fanartClientKeyController.text.trim(),
      fanartApiKeyOverride: _fanartApiKeyOverrideController.text.trim(),
      fanartBackupApiBase: _fanartApiBackupController.text.trim(),
      fanartBackupImageBase: _fanartImageBackupController.text.trim(),
      proxyMode: _proxyMode,
      proxyUrl: _proxyUrlController.text.trim(),
    );
  }

  void _scheduleAutoSave() {
    _hasPendingSave = true;
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(
      KonataTheme.settingsAutoSaveDebounce,
      () => unawaited(_flushAutoSave()),
    );
  }

  Future<void> _flushAutoSave() async {
    _autoSaveTimer?.cancel();
    _autoSaveTimer = null;
    if (!_hasPendingSave) return;
    _hasPendingSave = false;
    final nextConfig = _buildNetworkConfig();
    await _controller.saveNetworkConfig(nextConfig);
  }

  void _restoreTmdbDefaults() {
    setState(() {
      _tmdbApiBackupController.text =
          KonataNetworkConfig.defaultTmdbBackupApiBase;
      _tmdbImageBackupController.text =
          KonataNetworkConfig.defaultTmdbBackupImageBase;
    });
    _hasPendingSave = true;
    unawaited(_flushAutoSave());
    showKonataToast(context, '已恢复 TMDB 默认备用地址');
  }

  void _restoreBangumiDefaults() {
    setState(() {
      _bgmApiBackupController.text =
          KonataNetworkConfig.defaultBangumiBackupApiBase;
      _bgmImageBackupController.text =
          KonataNetworkConfig.defaultBangumiBackupImageBase;
    });
    _hasPendingSave = true;
    unawaited(_flushAutoSave());
    showKonataToast(context, '已恢复 Bangumi 默认备用地址');
  }

  void _restoreFanartDefaults() {
    setState(() {
      _fanartApiKeyOverrideController.text = '';
      _fanartApiBackupController.text =
          KonataNetworkConfig.builtInFanartRelayBase;
      _fanartImageBackupController.text = '';
    });
    _hasPendingSave = true;
    unawaited(_flushAutoSave());
    showKonataToast(context, '已恢复 Fanart.tv 默认内置中继设置');
  }

  Future<void> _runProbe(String label, String targetId) async {
    if (_hasPendingSave) {
      await _flushAutoSave();
    }
    if (!mounted) return;
    final report = await _controller.runConnectivityProbe(targetId);
    if (!mounted) return;
    showKonataToast(
      context,
      '$label：${report.displayText}',
      isError: !report.reachable,
    );
  }

  Future<void> _checkMappingUpdate() async {
    if (_hasPendingSave) {
      await _flushAutoSave();
    }
    if (!mounted) return;
    final result = await _controller.checkBangumiTmdbMappingUpdate();
    if (!mounted) return;
    showKonataToast(
      context,
      result.message,
      isError: result.state.name == 'failed',
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final controller = _controller;

    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildTmdbCredentialCard(p, controller),
            const SizedBox(height: 16),
            LayoutBuilder(
              builder: (context, constraints) {
                final tmdbCard = _buildTmdbCard(p, controller);
                final bgmCard = _buildBangumiCard(p, controller);
                if (constraints.maxWidth >= 760) {
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: tmdbCard),
                      const SizedBox(width: 16),
                      Expanded(child: bgmCard),
                    ],
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [tmdbCard, const SizedBox(height: 16), bgmCard],
                );
              },
            ),
            const SizedBox(height: 16),
            _buildFanartCard(p, controller),
            const SizedBox(height: 16),
            _buildProxyCard(p),
            const SizedBox(height: 16),
            _buildMappingCard(p, controller),
          ],
        );
      },
    );
  }

  Widget _buildTmdbCredentialCard(
    KonataPalette p,
    SettingsController controller,
  ) {
    return KonataSurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'TMDB API 密钥',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: p.textPrimary,
                    fontSize: KonataTheme.fontSizeTitleSm,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              KonataPillButton.ghost(
                label: '如何获取TMDB API',
                icon: Icons.help_outline_rounded,
                compact: true,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                onPressed: () => showTmdbApiHelpDialog(
                  context,
                  onOpenExternalUrl: controller.openExternalUrl,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          KonataSoftTextField(
            controller: _credentialController,
            obscureText: _obscureTmdb,
            hintText: '粘贴 TMDB v3 API Key 或 eyJ 开头的 v4 Read Access Token',
            prefixIcon: Icons.key_rounded,
            suffix: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _obscureTmdb = !_obscureTmdb),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: Icon(
                  _obscureTmdb
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  size: 16,
                  color: p.textSecondary,
                ),
              ),
            ),
            onChanged: (_) => _scheduleAutoSave(),
            onSubmitted: (_) => unawaited(_flushAutoSave()),
          ),
        ],
      ),
    );
  }

  Widget _buildTmdbCard(KonataPalette p, SettingsController controller) {
    final apiBusy = controller.isProbingTarget(NetworkProbeTargets.tmdbApi);
    final imgBusy = controller.isProbingTarget(NetworkProbeTargets.tmdbImage);
    return KonataSurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'TMDB 服务',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: p.textPrimary,
                    fontSize: KonataTheme.fontSizeTitleSm,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              KonataPillButton.ghost(
                label: '恢复默认',
                icon: Icons.restart_alt_rounded,
                compact: true,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                onPressed: _restoreTmdbDefaults,
              ),
            ],
          ),
          const SizedBox(height: 14),
          _EndpointBackupField(
            title: '备用 API 地址',
            officialSubtitle: '官方标准地址 · ${KonataNetworkConfig.defaultApiBase}',
            controller: _tmdbApiBackupController,
            hintText: KonataNetworkConfig.defaultTmdbBackupApiBase,
            buttonKey: const ValueKey<String>(
              'probe_${NetworkProbeTargets.tmdbApi}',
            ),
            testButtonLabel: apiBusy ? '测试中...' : 'API 连接测试',
            testing: apiBusy,
            report: controller.probeReports[NetworkProbeTargets.tmdbApi],
            onChanged: (_) => _scheduleAutoSave(),
            onSubmitted: (_) => unawaited(_flushAutoSave()),
            onTest: () =>
                _runProbe('TMDB API', NetworkProbeTargets.tmdbApi),
          ),
          const SizedBox(height: 16),
          _EndpointBackupField(
            title: '备用图片服务器地址',
            officialSubtitle:
                '官方标准地址 · ${KonataNetworkConfig.defaultImageBaseDisplay}',
            controller: _tmdbImageBackupController,
            hintText: KonataNetworkConfig.defaultTmdbBackupImageBase,
            buttonKey: const ValueKey<String>(
              'probe_${NetworkProbeTargets.tmdbImage}',
            ),
            testButtonLabel: imgBusy ? '测试中...' : '图片服务器连接测试',
            testing: imgBusy,
            report: controller.probeReports[NetworkProbeTargets.tmdbImage],
            onChanged: (_) => _scheduleAutoSave(),
            onSubmitted: (_) => unawaited(_flushAutoSave()),
            onTest: () =>
                _runProbe('TMDB 图片服务器', NetworkProbeTargets.tmdbImage),
          ),
        ],
      ),
    );
  }

  Widget _buildBangumiCard(KonataPalette p, SettingsController controller) {
    final apiBusy = controller.isProbingTarget(NetworkProbeTargets.bangumiApi);
    final imgBusy = controller.isProbingTarget(
      NetworkProbeTargets.bangumiImage,
    );
    return KonataSurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Bangumi 服务',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: p.textPrimary,
                    fontSize: KonataTheme.fontSizeTitleSm,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              KonataPillButton.ghost(
                label: '恢复默认',
                icon: Icons.restart_alt_rounded,
                compact: true,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                onPressed: _restoreBangumiDefaults,
              ),
            ],
          ),
          const SizedBox(height: 14),
          _EndpointBackupField(
            title: '备用 API 地址',
            officialSubtitle:
                '官方标准地址 · ${KonataNetworkConfig.defaultBangumiApiBase}',
            controller: _bgmApiBackupController,
            hintText: KonataNetworkConfig.defaultBangumiBackupApiBase,
            buttonKey: const ValueKey<String>(
              'probe_${NetworkProbeTargets.bangumiApi}',
            ),
            testButtonLabel: apiBusy ? '测试中...' : 'API 连接测试',
            testing: apiBusy,
            report: controller.probeReports[NetworkProbeTargets.bangumiApi],
            onChanged: (_) => _scheduleAutoSave(),
            onSubmitted: (_) => unawaited(_flushAutoSave()),
            onTest: () =>
                _runProbe('Bangumi API', NetworkProbeTargets.bangumiApi),
          ),
          const SizedBox(height: 16),
          _EndpointBackupField(
            title: '备用图片服务器地址',
            officialSubtitle:
                '官方标准地址 · ${KonataNetworkConfig.defaultBangumiImageBase}',
            controller: _bgmImageBackupController,
            hintText: KonataNetworkConfig.defaultBangumiBackupImageBase,
            buttonKey: const ValueKey<String>(
              'probe_${NetworkProbeTargets.bangumiImage}',
            ),
            testButtonLabel: imgBusy ? '测试中...' : '图片服务器连接测试',
            testing: imgBusy,
            report: controller.probeReports[NetworkProbeTargets.bangumiImage],
            onChanged: (_) => _scheduleAutoSave(),
            onSubmitted: (_) => unawaited(_flushAutoSave()),
            onTest: () =>
                _runProbe('Bangumi 图片服务器', NetworkProbeTargets.bangumiImage),
          ),
        ],
      ),
    );
  }

  Widget _buildFanartCard(KonataPalette p, SettingsController controller) {
    final fanartApiBusy = controller.isProbingTarget(
      NetworkProbeTargets.fanartApi,
    );
    final fanartImgBusy = controller.isProbingTarget(
      NetworkProbeTargets.fanartImage,
    );
    return KonataSurfaceCard(
      key: const ValueKey('settings_network_fanart_card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Fanart.tv 透明徽标',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: p.textPrimary,
                    fontSize: KonataTheme.fontSizeTitleSm,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              KonataPillButton.ghost(
                label: '获取个人 Key',
                icon: Icons.open_in_new_rounded,
                compact: true,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                onPressed: () => showFanartApiHelpDialog(
                  context,
                  onOpenExternalUrl: controller.openExternalUrl,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '选填，填入后可更快获取新番透明 Logo；留空时默认经内置无状态中继开箱即用',
            style: TextStyle(
              color: p.textMuted,
              fontSize: KonataTheme.fontSizeCaption,
            ),
          ),
          const SizedBox(height: 12),
          KonataSoftTextField(
            controller: _fanartClientKeyController,
            obscureText: _obscureFanart,
            label: 'Fanart.tv 个人密钥（Client Key · 选填）',
            hintText: '粘贴 Fanart.tv Personal API Key（留空不影响使用）',
            prefixIcon: Icons.key_rounded,
            suffix: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _obscureFanart = !_obscureFanart),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: Icon(
                  _obscureFanart
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  size: 16,
                  color: p.textSecondary,
                ),
              ),
            ),
            onChanged: (_) => _scheduleAutoSave(),
            onSubmitted: (_) => unawaited(_flushAutoSave()),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              KonataPillButton.ghost(
                label: _fanartAdvancedExpanded
                    ? '收起高级设置与连接测试'
                    : '高级设置与连接测试',
                icon: _fanartAdvancedExpanded
                    ? Icons.expand_less_rounded
                    : Icons.tune_rounded,
                compact: true,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                onPressed: () => setState(
                  () => _fanartAdvancedExpanded = !_fanartAdvancedExpanded,
                ),
              ),
              if (_fanartAdvancedExpanded)
                KonataPillButton.ghost(
                  label: '恢复默认',
                  icon: Icons.restart_alt_rounded,
                  compact: true,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  onPressed: _restoreFanartDefaults,
                ),
            ],
          ),
          KonataSmoothSectionSwitcher(
            switchKey: _fanartAdvancedExpanded,
            alignment: Alignment.topLeft,
            child: _fanartAdvancedExpanded
                ? Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        KonataSoftTextField(
                          controller: _fanartApiKeyOverrideController,
                          obscureText: _obscureFanart,
                          dense: true,
                          label: '自定义项目 API Key（api-key · 选填覆盖内置中继）',
                          hintText: '仅在内置中继受限或需直连官方 Fanart.tv 时填写',
                          prefixIcon: Icons.vpn_key_outlined,
                          onChanged: (_) => _scheduleAutoSave(),
                          onSubmitted: (_) => unawaited(_flushAutoSave()),
                        ),
                        const SizedBox(height: 14),
                        _EndpointBackupField(
                          title: '中继 / 备用 API 地址',
                          officialSubtitle:
                              '官方标准地址 · ${KonataNetworkConfig.defaultFanartApiBase}',
                          controller: _fanartApiBackupController,
                          hintText:
                              KonataNetworkConfig.builtInFanartRelayBase.isNotEmpty
                              ? KonataNetworkConfig.builtInFanartRelayBase
                              : 'https://relay.example.com',
                          buttonKey: const ValueKey<String>(
                            'probe_${NetworkProbeTargets.fanartApi}',
                          ),
                          testButtonLabel: fanartApiBusy
                              ? '测试中...'
                              : 'API 连接测试',
                          testing: fanartApiBusy,
                          report: controller
                              .probeReports[NetworkProbeTargets.fanartApi],
                          onChanged: (_) => _scheduleAutoSave(),
                          onSubmitted: (_) => unawaited(_flushAutoSave()),
                          onTest: () => _runProbe(
                            'Fanart.tv API',
                            NetworkProbeTargets.fanartApi,
                          ),
                        ),
                        const SizedBox(height: 14),
                        _EndpointBackupField(
                          title: '备用图片服务器地址',
                          officialSubtitle:
                              '官方标准地址 · ${KonataNetworkConfig.defaultFanartImageBase}',
                          controller: _fanartImageBackupController,
                          hintText: '选填自定义 assets.fanart.tv 图片反代地址',
                          buttonKey: const ValueKey<String>(
                            'probe_${NetworkProbeTargets.fanartImage}',
                          ),
                          testButtonLabel: fanartImgBusy
                              ? '测试中...'
                              : '图片服务器连接测试',
                          testing: fanartImgBusy,
                          report: controller
                              .probeReports[NetworkProbeTargets.fanartImage],
                          onChanged: (_) => _scheduleAutoSave(),
                          onSubmitted: (_) => unawaited(_flushAutoSave()),
                          onTest: () => _runProbe(
                            'Fanart.tv 图片服务器',
                            NetworkProbeTargets.fanartImage,
                          ),
                        ),
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _buildProxyCard(KonataPalette p) {
    return KonataSurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '网络代理',
            style: TextStyle(
              color: p.textPrimary,
              fontSize: KonataTheme.fontSizeSubtitle,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          KonataSegmentedCapsule<ProxyMode>(
            selected: _proxyMode,
            options: const [
              KonataSegmentOption(value: ProxyMode.system, label: '系统代理'),
              KonataSegmentOption(value: ProxyMode.custom, label: '自定义代理'),
              KonataSegmentOption(value: ProxyMode.none, label: '不使用代理'),
            ],
            onChanged: (v) {
              if (_proxyMode == v) return;
              setState(() => _proxyMode = v);
              _hasPendingSave = true;
              unawaited(_flushAutoSave());
            },
          ),
          KonataSmoothSectionSwitcher(
            switchKey: _proxyMode == ProxyMode.custom,
            alignment: Alignment.topLeft,
            child: _proxyMode == ProxyMode.custom
                ? Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: KonataSoftTextField(
                      controller: _proxyUrlController,
                      label: '代理服务器地址',
                      hintText: KonataNetworkConfig.defaultLocalProxyHint,
                      prefixIcon: Icons.lan_outlined,
                      onChanged: (_) => _scheduleAutoSave(),
                      onSubmitted: (_) => unawaited(_flushAutoSave()),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _buildMappingCard(KonataPalette p, SettingsController controller) {
    final snapshot = controller.mappingSnapshot;
    final result = controller.mappingUpdateResult;
    final updating = controller.isUpdatingMapping;
    final statusLine = snapshot == null
        ? '正在读取本地离线映射表...'
        : [
            '已载入 ${snapshot.uniqueBangumiCount} 条动画映射',
            if (snapshot.snapshotDate.isNotEmpty) '快照 ${snapshot.snapshotDate}',
            snapshot.sourceLabel,
          ].join(' · ');

    return KonataSurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '离线动画映射表',
            style: TextStyle(
              color: p.textPrimary,
              fontSize: KonataTheme.fontSizeSubtitle,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '内置 Bangumi ↔ TMDB 索引，扫描前每 24 小时自动静默检查增量快照',
            style: TextStyle(
              color: p.textMuted,
              fontSize: KonataTheme.fontSizeCaption,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            statusLine,
            style: TextStyle(
              color: p.textSecondary,
              fontSize: KonataTheme.fontSizeBody,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 12,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              KonataPillButton.secondary(
                label: updating ? '检查中...' : '检查更新',
                icon: Icons.sync_rounded,
                compact: true,
                onPressed: updating ? null : () => unawaited(_checkMappingUpdate()),
              ),
              if (result != null)
                Text(
                  result.message,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: result.state.name == 'failed' ? p.danger : p.success,
                    fontSize: KonataTheme.fontSizeCaption,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _EndpointBackupField extends StatelessWidget {
  const _EndpointBackupField({
    required this.title,
    required this.officialSubtitle,
    required this.controller,
    required this.hintText,
    required this.buttonKey,
    required this.testButtonLabel,
    required this.testing,
    required this.report,
    required this.onChanged,
    required this.onSubmitted,
    required this.onTest,
  });

  final String title;
  final String officialSubtitle;
  final TextEditingController controller;
  final String hintText;
  final Key buttonKey;
  final String testButtonLabel;
  final bool testing;
  final ConnectivityReport? report;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onTest;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            color: p.textPrimary,
            fontSize: KonataTheme.fontSizeBody,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          officialSubtitle,
          style: TextStyle(
            color: p.textMuted,
            fontSize: KonataTheme.fontSizeCaption,
          ),
        ),
        const SizedBox(height: 8),
        KonataSoftTextField(
          controller: controller,
          dense: true,
          hintText: hintText,
          onChanged: onChanged,
          onSubmitted: onSubmitted,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            KonataPillButton.secondary(
              key: buttonKey,
              label: testButtonLabel,
              icon: Icons.network_check_rounded,
              compact: true,
              onPressed: testing ? null : onTest,
            ),
            if (report != null)
              Text(
                report!.displayText,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: report!.reachable
                      ? (report!.usedBackup ? p.warning : p.success)
                      : p.danger,
                  fontSize: KonataTheme.fontSizeCaption,
                ),
              ),
          ],
        ),
      ],
    );
  }
}
