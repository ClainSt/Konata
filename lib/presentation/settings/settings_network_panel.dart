import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/scraping_providers.dart';
import '../../application/providers/source_actions_provider.dart';
import '../../domain/models/network_config.dart';
import '../../domain/models/tmdb_models.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/konata_glass_dialog.dart';
import '../widgets/design_system/konata_pill_button.dart';
import '../widgets/design_system/konata_segmented_capsule.dart';
import '../widgets/design_system/konata_soft_text_field.dart';
import '../widgets/design_system/konata_surface_card.dart';
import '../widgets/design_system/konata_toast.dart';
import 'tmdb_api_help_dialog.dart';

/// 刮削与网络设置面板（官方优先 + 备用地址自动回退 + 四通道独立连通性测试）。
class SettingsNetworkPanel extends ConsumerStatefulWidget {
  /// 创建刮削与网络面板。
  const SettingsNetworkPanel({super.key});

  @override
  ConsumerState<SettingsNetworkPanel> createState() =>
      _SettingsNetworkPanelState();
}

class _SettingsNetworkPanelState extends ConsumerState<SettingsNetworkPanel> {
  final TextEditingController _credentialController = TextEditingController();
  final TextEditingController _tmdbApiBackupController = TextEditingController();
  final TextEditingController _tmdbImageBackupController =
      TextEditingController();
  final TextEditingController _bgmApiBackupController = TextEditingController();
  final TextEditingController _bgmImageBackupController =
      TextEditingController();
  final TextEditingController _proxyUrlController = TextEditingController();

  ProxyMode _proxyMode = ProxyMode.system;
  bool _initializedNetwork = false;

  bool _testingTmdbApi = false;
  bool _testingTmdbImage = false;
  bool _testingBgmApi = false;
  bool _testingBgmImage = false;

  ConnectivityReport? _tmdbApiReport;
  ConnectivityReport? _tmdbImageReport;
  ConnectivityReport? _bgmApiReport;
  ConnectivityReport? _bgmImageReport;

  @override
  void dispose() {
    _credentialController.dispose();
    _tmdbApiBackupController.dispose();
    _tmdbImageBackupController.dispose();
    _bgmApiBackupController.dispose();
    _bgmImageBackupController.dispose();
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
      proxyMode: _proxyMode,
      proxyUrl: _proxyUrlController.text.trim(),
    );
  }

  Future<void> _saveNetwork() async {
    await ref
        .read(konataActionsProvider)
        .saveNetworkConfig(_buildNetworkConfig());
    if (mounted) {
      showKonataToast(context, '刮削与网络配置已保存');
    }
  }

  void _restoreTmdbDefaults() {
    setState(() {
      _tmdbApiBackupController.text =
          TmdbNetworkConfig.defaultTmdbBackupApiBase;
      _tmdbImageBackupController.text =
          TmdbNetworkConfig.defaultTmdbBackupImageBase;
      _tmdbApiReport = null;
      _tmdbImageReport = null;
    });
    showKonataToast(context, '已恢复 TMDB 默认备用地址');
  }

  void _restoreBangumiDefaults() {
    setState(() {
      _bgmApiBackupController.text =
          TmdbNetworkConfig.defaultBangumiBackupApiBase;
      _bgmImageBackupController.text =
          TmdbNetworkConfig.defaultBangumiBackupImageBase;
      _bgmApiReport = null;
      _bgmImageReport = null;
    });
    showKonataToast(context, '已恢复 Bangumi 默认备用地址');
  }

  Future<void> _runProbe(
    Future<ConnectivityReport> Function(TmdbNetworkConfig cfg) runner,
    void Function(bool busy) setBusy,
    void Function(ConnectivityReport report) setReport,
  ) async {
    setState(() => setBusy(true));
    final report = await runner(_buildNetworkConfig());
    if (!mounted) return;
    setState(() {
      setBusy(false);
      setReport(report);
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
        _proxyMode = cfg.proxyMode;
        _proxyUrlController.text = cfg.proxyUrl;
      }
    });

    final actions = ref.read(konataActionsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '刮削与网络',
          style: KonataTheme.h2Style(p),
        ),
        const SizedBox(height: 6),
        Text(
          '刮削优先连接官方服务；当官方地址连接超时或在中国大陆网络受阻时，将自动无缝回退至下方配置的备用地址。',
          style: KonataTheme.captionStyle(p, fontSize: 13, height: 1.45),
        ),
        const SizedBox(height: 18),
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
              children: [
                tmdbCard,
                const SizedBox(height: 16),
                bgmCard,
              ],
            );
          },
        ),
        const SizedBox(height: 16),
        _buildProxyCard(p),
        const SizedBox(height: 18),
        Align(
          alignment: Alignment.centerLeft,
          child: KonataPillButton.primary(
            label: '保存网络配置',
            icon: Icons.save_outlined,
            onPressed: _saveNetwork,
          ),
        ),
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
              Text(
                'TMDB API 密钥',
                style: TextStyle(
                  color: p.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              KonataPillButton.ghost(
                label: '如何获取TMDB API',
                icon: Icons.help_outline_rounded,
                compact: true,
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 6,
                ),
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
              Text(
                'TMDB 服务',
                style: TextStyle(
                  color: p.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              KonataPillButton.ghost(
                label: '恢复默认',
                icon: Icons.restart_alt_rounded,
                compact: true,
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 6,
                ),
                onPressed: _restoreTmdbDefaults,
              ),
            ],
          ),
          const SizedBox(height: 14),
          _EndpointBackupField(
            title: '备用 API 地址',
            officialSubtitle:
                '官方标准地址 · ${TmdbNetworkConfig.defaultApiBase}',
            controller: _tmdbApiBackupController,
            hintText: TmdbNetworkConfig.defaultTmdbBackupApiBase,
            testButtonLabel: _testingTmdbApi ? '测试中...' : 'API 连接测试',
            testing: _testingTmdbApi,
            report: _tmdbApiReport,
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
              Text(
                'Bangumi 服务',
                style: TextStyle(
                  color: p.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              KonataPillButton.ghost(
                label: '恢复默认',
                icon: Icons.restart_alt_rounded,
                compact: true,
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 6,
                ),
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

  Widget _buildProxyCard(KonataPalette p) {
    return KonataSurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '网络代理（可选）',
            style: TextStyle(
              color: p.textPrimary,
              fontSize: 14.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          KonataSegmentedCapsule<ProxyMode>(
            selected: _proxyMode,
            options: const [
              KonataSegmentOption(
                value: ProxyMode.system,
                label: '跟随系统代理（默认）',
              ),
              KonataSegmentOption(
                value: ProxyMode.custom,
                label: '自定义本地代理',
              ),
              KonataSegmentOption(
                value: ProxyMode.none,
                label: '不使用代理',
              ),
            ],
            onChanged: (v) => setState(() => _proxyMode = v),
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
                    ),
                  )
                : const SizedBox.shrink(),
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
    required this.onTest,
  });

  final String title;
  final String officialSubtitle;
  final TextEditingController controller;
  final String hintText;
  final String testButtonLabel;
  final bool testing;
  final ConnectivityReport? report;
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
            fontSize: 13.5,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          officialSubtitle,
          style: TextStyle(color: p.textMuted, fontSize: 11.8),
        ),
        const SizedBox(height: 8),
        KonataSoftTextField(
          controller: controller,
          dense: true,
          hintText: hintText,
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            KonataPillButton.secondary(
              label: testButtonLabel,
              icon: Icons.network_check_rounded,
              compact: true,
              onPressed: testing ? null : onTest,
            ),
            if (report != null) ...[
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  report!.displayText,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: report!.reachable
                        ? (report!.usedBackup ? p.warning : p.success)
                        : p.danger,
                    fontSize: 12.2,
                  ),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}
