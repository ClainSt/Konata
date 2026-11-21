import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/scraping_providers.dart';
import '../../application/providers/source_actions_provider.dart';
import '../../domain/models/network_config.dart';
import '../../domain/models/tmdb_models.dart';
import '../../domain/scraping/bangumi_tmdb_index.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/konata_glass_dialog.dart';
import '../widgets/design_system/konata_pill_button.dart';
import '../widgets/design_system/konata_segmented_capsule.dart';
import '../widgets/design_system/konata_soft_text_field.dart';
import '../widgets/design_system/konata_surface_card.dart';
import '../widgets/design_system/konata_toast.dart';
import 'fanart_api_help_dialog.dart';
import 'tmdb_api_help_dialog.dart';

/// 刮削与网络设置面板（官方优先 + 备用地址自动回退 + 即时自动持久化 + 四通道独立连通性测试）。
class SettingsNetworkPanel extends ConsumerStatefulWidget {
  /// 创建刮削与网络面板。
  const SettingsNetworkPanel({super.key});

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
  bool _initializedNetwork = false;
  bool _fanartAdvancedExpanded = false;
  bool _hasPendingSave = false;
  Timer? _autoSaveTimer;
  KonataActionsCoordinator? _actions;

  bool _testingTmdbApi = false;
  bool _testingTmdbImage = false;
  bool _testingBgmApi = false;
  bool _testingBgmImage = false;
  bool _testingFanartApi = false;
  bool _testingFanartImage = false;
  bool _updatingMapping = false;

  ConnectivityReport? _tmdbApiReport;
  ConnectivityReport? _tmdbImageReport;
  ConnectivityReport? _bgmApiReport;
  ConnectivityReport? _bgmImageReport;
  ConnectivityReport? _fanartApiReport;
  ConnectivityReport? _fanartImageReport;
  BangumiTmdbUpdateResult? _mappingUpdateResult;

  @override
  void dispose() {
    _autoSaveTimer?.cancel();
    _autoSaveTimer = null;
    final pendingActions = _actions;
    if (_hasPendingSave && pendingActions != null) {
      _hasPendingSave = false;
      unawaited(pendingActions.saveNetworkConfig(_buildNetworkConfig()));
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

  TmdbNetworkConfig _buildNetworkConfig() {
    return TmdbNetworkConfig(
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
    _initializedNetwork = true;
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
    final coordinator =
        _actions ?? (mounted ? ref.read(konataActionsProvider) : null);
    if (coordinator == null) return;
    _hasPendingSave = false;
    await coordinator.saveNetworkConfig(_buildNetworkConfig());
  }

  void _restoreTmdbDefaults() {
    setState(() {
      _initializedNetwork = true;
      _tmdbApiBackupController.text =
          TmdbNetworkConfig.defaultTmdbBackupApiBase;
      _tmdbImageBackupController.text =
          TmdbNetworkConfig.defaultTmdbBackupImageBase;
      _tmdbApiReport = null;
      _tmdbImageReport = null;
    });
    _hasPendingSave = true;
    unawaited(_flushAutoSave());
    showKonataToast(context, '已恢复 TMDB 默认备用地址');
  }

  void _restoreBangumiDefaults() {
    setState(() {
      _initializedNetwork = true;
      _bgmApiBackupController.text =
          TmdbNetworkConfig.defaultBangumiBackupApiBase;
      _bgmImageBackupController.text =
          TmdbNetworkConfig.defaultBangumiBackupImageBase;
      _bgmApiReport = null;
      _bgmImageReport = null;
    });
    _hasPendingSave = true;
    unawaited(_flushAutoSave());
    showKonataToast(context, '已恢复 Bangumi 默认备用地址');
  }

  void _restoreFanartDefaults() {
    setState(() {
      _initializedNetwork = true;
      _fanartApiKeyOverrideController.text = '';
      _fanartApiBackupController.text =
          TmdbNetworkConfig.builtInFanartRelayBase;
      _fanartImageBackupController.text = '';
      _fanartApiReport = null;
      _fanartImageReport = null;
    });
    _hasPendingSave = true;
    unawaited(_flushAutoSave());
    showKonataToast(context, '已恢复 Fanart.tv 默认内置中继设置');
  }

  Future<void> _runProbe(
    Future<ConnectivityReport> Function(TmdbNetworkConfig cfg) runner,
    void Function(bool busy) setBusy,
    void Function(ConnectivityReport report) setReport,
  ) async {
    if (_hasPendingSave) {
      await _flushAutoSave();
    }
    if (!mounted) return;
    setState(() => setBusy(true));
    final report = await runner(_buildNetworkConfig());
    if (!mounted) return;
    setState(() {
      setBusy(false);
      setReport(report);
    });
  }

  Future<void> _checkMappingUpdate(KonataActionsCoordinator actions) async {
    if (_hasPendingSave) {
      await _flushAutoSave();
    }
    if (!mounted) return;
    setState(() => _updatingMapping = true);
    final result = await actions.checkBangumiTmdbMappingUpdate(
      _buildNetworkConfig(),
    );
    if (!mounted) return;
    setState(() {
      _updatingMapping = false;
      _mappingUpdateResult = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final netAsync = ref.watch(tmdbNetworkConfigProvider);

    netAsync.whenData((cfg) {
      if (!_initializedNetwork) {
        _initializedNetwork = true;
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
      }
    });

    final actions = ref.read(konataActionsProvider);
    _actions = actions;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildTmdbCredentialCard(p),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) {
            final tmdbCard = _buildTmdbCard(p, actions);
            final bgmCard = _buildBangumiCard(p, actions);
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
        _buildFanartCard(p, actions),
        const SizedBox(height: 16),
        _buildProxyCard(p),
        const SizedBox(height: 16),
        _buildMappingCard(p, actions),
      ],
    );
  }

  Widget _buildTmdbCredentialCard(KonataPalette p) {
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
                onPressed: () {
                  showKonataGlassDialog<void>(
                    context: context,
                    builder: (_) => const TmdbApiHelpDialog(),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 12),
          KonataSoftTextField(
            controller: _credentialController,
            obscureText: true,
            hintText: '粘贴 TMDB v3 API Key 或 eyJ 开头的 v4 Read Access Token',
            prefixIcon: Icons.key_rounded,
            onChanged: (_) => _scheduleAutoSave(),
            onSubmitted: (_) => unawaited(_flushAutoSave()),
          ),
        ],
      ),
    );
  }

  Widget _buildTmdbCard(KonataPalette p, KonataActionsCoordinator actions) {
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
            officialSubtitle: '官方标准地址 · ${TmdbNetworkConfig.defaultApiBase}',
            controller: _tmdbApiBackupController,
            hintText: TmdbNetworkConfig.defaultTmdbBackupApiBase,
            testButtonLabel: _testingTmdbApi ? '测试中...' : 'API 连接测试',
            testing: _testingTmdbApi,
            report: _tmdbApiReport,
            onChanged: (_) => _scheduleAutoSave(),
            onSubmitted: (_) => unawaited(_flushAutoSave()),
            onTest: () => _runProbe(
              actions.testTmdbApiConnectivity,
              (b) => _testingTmdbApi = b,
              (r) => _tmdbApiReport = r,
            ),
          ),
          const SizedBox(height: 16),
          _EndpointBackupField(
            title: '备用图片服务器地址',
            officialSubtitle:
                '官方标准地址 · ${TmdbNetworkConfig.defaultImageBaseDisplay}',
            controller: _tmdbImageBackupController,
            hintText: TmdbNetworkConfig.defaultTmdbBackupImageBase,
            testButtonLabel: _testingTmdbImage ? '测试中...' : '图片服务器连接测试',
            testing: _testingTmdbImage,
            report: _tmdbImageReport,
            onChanged: (_) => _scheduleAutoSave(),
            onSubmitted: (_) => unawaited(_flushAutoSave()),
            onTest: () => _runProbe(
              actions.testTmdbImageConnectivity,
              (b) => _testingTmdbImage = b,
              (r) => _tmdbImageReport = r,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBangumiCard(KonataPalette p, KonataActionsCoordinator actions) {
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
                '官方标准地址 · ${TmdbNetworkConfig.defaultBangumiApiBase}',
            controller: _bgmApiBackupController,
            hintText: TmdbNetworkConfig.defaultBangumiBackupApiBase,
            testButtonLabel: _testingBgmApi ? '测试中...' : 'API 连接测试',
            testing: _testingBgmApi,
            report: _bgmApiReport,
            onChanged: (_) => _scheduleAutoSave(),
            onSubmitted: (_) => unawaited(_flushAutoSave()),
            onTest: () => _runProbe(
              actions.testBangumiApiConnectivity,
              (b) => _testingBgmApi = b,
              (r) => _bgmApiReport = r,
            ),
          ),
          const SizedBox(height: 16),
          _EndpointBackupField(
            title: '备用图片服务器地址',
            officialSubtitle:
                '官方标准地址 · ${TmdbNetworkConfig.defaultBangumiImageBase}',
            controller: _bgmImageBackupController,
            hintText: TmdbNetworkConfig.defaultBangumiBackupImageBase,
            testButtonLabel: _testingBgmImage ? '测试中...' : '图片服务器连接测试',
            testing: _testingBgmImage,
            report: _bgmImageReport,
            onChanged: (_) => _scheduleAutoSave(),
            onSubmitted: (_) => unawaited(_flushAutoSave()),
            onTest: () => _runProbe(
              actions.testBangumiImageConnectivity,
              (b) => _testingBgmImage = b,
              (r) => _bgmImageReport = r,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFanartCard(KonataPalette p, KonataActionsCoordinator actions) {
    final relayHealth = ref.watch(fanartRelayHealthProvider);
    final hasCustomApi =
        TmdbNetworkConfig.resolveEffectiveFanartApiKey(
          manualOverride: _fanartApiKeyOverrideController.text,
        ).isNotEmpty;

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
                onPressed: () {
                  showKonataGlassDialog<void>(
                    context: context,
                    builder: (_) => const FanartApiHelpDialog(),
                  );
                },
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
            obscureText: true,
            label: 'Fanart.tv 个人密钥（Client Key · 选填）',
            hintText: '粘贴 Fanart.tv Personal API Key（留空不影响使用）',
            prefixIcon: Icons.key_rounded,
            onChanged: (_) => _scheduleAutoSave(),
            onSubmitted: (_) => unawaited(_flushAutoSave()),
          ),
          if (!hasCustomApi &&
              relayHealth.isDegraded &&
              relayHealth.message != null) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: p.warning.withValues(alpha: 0.14),
                borderRadius: KonataTheme.borderRadiusSm,
                border: Border.all(
                  color: p.warning.withValues(alpha: 0.35),
                  width: 0.9,
                ),
              ),
              child: Text(
                relayHealth.message!,
                style: TextStyle(
                  color: p.warning,
                  fontSize: KonataTheme.fontSizeCaption,
                  height: 1.45,
                ),
              ),
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              KonataPillButton.ghost(
                label: _fanartAdvancedExpanded ? '收起高级设置与连接测试' : '高级设置与连接测试',
                icon: _fanartAdvancedExpanded
                    ? Icons.expand_less_rounded
                    : Icons.tune_rounded,
                compact: true,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                onPressed: () {
                  setState(
                    () => _fanartAdvancedExpanded = !_fanartAdvancedExpanded,
                  );
                },
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
                          obscureText: true,
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
                              '官方标准地址 · ${TmdbNetworkConfig.defaultFanartApiBase}',
                          controller: _fanartApiBackupController,
                          hintText:
                              TmdbNetworkConfig.builtInFanartRelayBase.isNotEmpty
                                  ? TmdbNetworkConfig.builtInFanartRelayBase
                                  : 'https://relay.example.com',
                          testButtonLabel: _testingFanartApi
                              ? '测试中...'
                              : 'API 连接测试',
                          testing: _testingFanartApi,
                          report: _fanartApiReport,
                          onChanged: (_) => _scheduleAutoSave(),
                          onSubmitted: (_) => unawaited(_flushAutoSave()),
                          onTest: () => _runProbe(
                            actions.testFanartApiConnectivity,
                            (b) => _testingFanartApi = b,
                            (r) => _fanartApiReport = r,
                          ),
                        ),
                        const SizedBox(height: 14),
                        _EndpointBackupField(
                          title: '备用图片服务器地址',
                          officialSubtitle:
                              '官方标准地址 · ${TmdbNetworkConfig.defaultFanartImageBase}',
                          controller: _fanartImageBackupController,
                          hintText: '选填自定义 assets.fanart.tv 图片反代地址',
                          testButtonLabel: _testingFanartImage
                              ? '测试中...'
                              : '图片服务器连接测试',
                          testing: _testingFanartImage,
                          report: _fanartImageReport,
                          onChanged: (_) => _scheduleAutoSave(),
                          onSubmitted: (_) => unawaited(_flushAutoSave()),
                          onTest: () => _runProbe(
                            actions.testFanartImageConnectivity,
                            (b) => _testingFanartImage = b,
                            (r) => _fanartImageReport = r,
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
              setState(() {
                _initializedNetwork = true;
                _proxyMode = v;
              });
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
                      hintText: TmdbNetworkConfig.defaultLocalProxyHint,
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

  Widget _buildMappingCard(
    KonataPalette p,
    KonataActionsCoordinator actions,
  ) {
    final snapshotAsync = ref.watch(bangumiTmdbSnapshotProvider);
    final snapshot = _mappingUpdateResult?.snapshot ?? snapshotAsync.valueOrNull;
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
                label: _updatingMapping ? '检查中...' : '检查更新',
                icon: Icons.sync_rounded,
                compact: true,
                onPressed: _updatingMapping
                    ? null
                    : () => unawaited(_checkMappingUpdate(actions)),
              ),
              if (_mappingUpdateResult != null)
                Text(
                  _mappingUpdateResult!.message,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color:
                        _mappingUpdateResult!.state ==
                            BangumiTmdbUpdateState.failed
                        ? p.danger
                        : p.success,
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
          style: TextStyle(color: p.textMuted, fontSize: KonataTheme.fontSizeCaption),
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
