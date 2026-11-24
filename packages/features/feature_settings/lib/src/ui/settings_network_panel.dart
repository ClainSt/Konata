import 'package:engine_sources/engine_sources.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../providers.dart';
import '../state/settings_controller.dart';
import 'fanart_api_help_dialog.dart';
import 'settings_shared_widgets.dart';
import 'tmdb_api_help_dialog.dart';

/// 网络代理、元数据凭据与备用镜像通用设置面板（纯设计系统组件实现）。
class SettingsNetworkPanel extends ConsumerStatefulWidget {
  /// 创建网络与元数据凭据设置面板。
  const SettingsNetworkPanel({super.key, this.controller});

  /// 可选直传设置控制器；为空时从 [settingsControllerProvider] 获取。
  final SettingsController? controller;

  @override
  ConsumerState<SettingsNetworkPanel> createState() =>
      _SettingsNetworkPanelState();
}

class _SettingsNetworkPanelState extends ConsumerState<SettingsNetworkPanel> {
  final TextEditingController _tmdbCredentialCtrl = TextEditingController();
  final TextEditingController _fanartClientKeyCtrl = TextEditingController();
  final TextEditingController _fanartApiOverrideCtrl = TextEditingController();
  final TextEditingController _tmdbBackupApiCtrl = TextEditingController();
  final TextEditingController _tmdbBackupImageCtrl = TextEditingController();
  final TextEditingController _bangumiBackupApiCtrl = TextEditingController();
  final TextEditingController _bangumiBackupImageCtrl = TextEditingController();
  final TextEditingController _fanartBackupApiCtrl = TextEditingController();
  final TextEditingController _fanartBackupImageCtrl = TextEditingController();
  final TextEditingController _proxyUrlCtrl = TextEditingController();

  bool _obscureTmdb = true;
  bool _obscureFanart = true;
  bool _showAdvancedMirrors = false;
  ProxyMode _proxyMode = ProxyMode.system;
  bool _hydratedOnce = false;
  SettingsController? _observedController;

  SettingsController get _controller =>
      widget.controller ?? ref.read(settingsControllerProvider);

  @override
  void initState() {
    super.initState();
  }

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
    if (!mounted) {
      return;
    }
    final ctrl = _observedController;
    if (ctrl != null && !_hydratedOnce && !ctrl.isLoadingNetwork) {
      _syncFieldsFromConfig(ctrl.networkConfig, force: true);
    }
  }

  void _syncFieldsFromConfig(
    KonataNetworkConfig cfg, {
    required bool force,
  }) {
    if (!force && _hydratedOnce) {
      return;
    }
    _tmdbCredentialCtrl.text = cfg.credential;
    _fanartClientKeyCtrl.text = cfg.fanartClientKey;
    _fanartApiOverrideCtrl.text = cfg.fanartApiKeyOverride;
    _tmdbBackupApiCtrl.text = cfg.tmdbBackupApiBase;
    _tmdbBackupImageCtrl.text = cfg.tmdbBackupImageBase;
    _bangumiBackupApiCtrl.text = cfg.bangumiBackupApiBase;
    _bangumiBackupImageCtrl.text = cfg.bangumiBackupImageBase;
    _fanartBackupApiCtrl.text = cfg.fanartBackupApiBase;
    _fanartBackupImageCtrl.text = cfg.fanartBackupImageBase;
    _proxyMode = cfg.proxyMode;
    _proxyUrlCtrl.text = cfg.proxyUrl;
    if (!_controller.isLoadingNetwork) {
      _hydratedOnce = true;
    }
  }

  @override
  void dispose() {
    _observedController?.removeListener(_onControllerUpdated);
    _tmdbCredentialCtrl.dispose();
    _fanartClientKeyCtrl.dispose();
    _fanartApiOverrideCtrl.dispose();
    _tmdbBackupApiCtrl.dispose();
    _tmdbBackupImageCtrl.dispose();
    _bangumiBackupApiCtrl.dispose();
    _bangumiBackupImageCtrl.dispose();
    _fanartBackupApiCtrl.dispose();
    _fanartBackupImageCtrl.dispose();
    _proxyUrlCtrl.dispose();
    super.dispose();
  }

  Future<void> _onSave() async {
    final next = KonataNetworkConfig(
      credential: _tmdbCredentialCtrl.text.trim(),
      fanartClientKey: _fanartClientKeyCtrl.text.trim(),
      fanartApiKeyOverride: _fanartApiOverrideCtrl.text.trim(),
      tmdbBackupApiBase: _tmdbBackupApiCtrl.text.trim(),
      tmdbBackupImageBase: _tmdbBackupImageCtrl.text.trim(),
      bangumiBackupApiBase: _bangumiBackupApiCtrl.text.trim(),
      bangumiBackupImageBase: _bangumiBackupImageCtrl.text.trim(),
      fanartBackupApiBase: _fanartBackupApiCtrl.text.trim(),
      fanartBackupImageBase: _fanartBackupImageCtrl.text.trim(),
      proxyMode: _proxyMode,
      proxyUrl: _proxyUrlCtrl.text.trim(),
    );
    await _controller.saveNetworkConfig(next);
    if (mounted) {
      showKonataToast(context, '网络与元数据凭据配置已保存');
    }
  }

  Future<void> _onResetMirrors() async {
    await _controller.resetMirrorsAndProxyPreservingKeys();
    _hydratedOnce = false;
    _syncFieldsFromConfig(_controller.networkConfig, force: true);
    if (mounted) {
      setState(() {});
      showKonataToast(context, '已恢复默认备用镜像与代理设置');
    }
  }

  String _resolveTmdbKindLabel() {
    final val = _tmdbCredentialCtrl.text.trim();
    if (val.isEmpty) {
      return '未配置';
    }
    return val.startsWith('eyJ') ? '识别为 v4 Token' : '识别为 v3 API Key';
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final tokens = Theme.of(context).extension<KonataPalette>()!;

    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final saving = controller.isSavingNetwork;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            KonataSurfaceCard(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SettingsSectionHeader(
                    icon: Icons.vpn_key_outlined,
                    title: '元数据凭据（安全存储）',
                    subtitle: 'TMDB 与 Fanart 密钥均保存在系统安全凭据库中，不随普通偏好明文落盘',
                  ),
                  const SizedBox(height: 16),
                  SettingsFieldLabel(
                    label: 'TMDB API 密钥 / v4 读取令牌',
                    badgeText: _resolveTmdbKindLabel(),
                    onHelpTap: () => showTmdbApiHelpDialog(
                      context,
                      onOpenExternalUrl: controller.openExternalUrl,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: KonataSoftTextField(
                          controller: _tmdbCredentialCtrl,
                          hintText: '粘贴 32 位 v3 API Key 或 eyJ 开头的 v4 Token',
                          obscureText: _obscureTmdb,
                          prefixIcon: Icons.key_outlined,
                          onChanged: (_) => setState(() {}),
                        ),
                      ),
                      const SizedBox(width: 8),
                      KonataPillButton.ghost(
                        label: _obscureTmdb ? '显示' : '隐藏',
                        compact: true,
                        onPressed: () {
                          setState(() {
                            _obscureTmdb = !_obscureTmdb;
                          });
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  SettingsFieldLabel(
                    label: 'Fanart.tv 个人客户端密钥（选填）',
                    onHelpTap: () => showFanartApiHelpDialog(
                      context,
                      onOpenExternalUrl: controller.openExternalUrl,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: KonataSoftTextField(
                          controller: _fanartClientKeyCtrl,
                          hintText: '可选填 Fanart Client Key，加速新番艺术图可见',
                          obscureText: _obscureFanart,
                          prefixIcon: Icons.auto_awesome_outlined,
                        ),
                      ),
                      const SizedBox(width: 8),
                      KonataPillButton.ghost(
                        label: _obscureFanart ? '显示' : '隐藏',
                        compact: true,
                        onPressed: () {
                          setState(() {
                            _obscureFanart = !_obscureFanart;
                          });
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const SettingsFieldLabel(
                    label: 'Fanart 自定义项目密钥（可选高阶直连）',
                  ),
                  const SizedBox(height: 8),
                  KonataSoftTextField(
                    controller: _fanartApiOverrideCtrl,
                    hintText: '留空则由中继或内置通道自动调度',
                    obscureText: _obscureFanart,
                    prefixIcon: Icons.shield_outlined,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            KonataSurfaceCard(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SettingsSectionHeader(
                    icon: Icons.public_outlined,
                    title: '网络代理与备用回退镜像',
                    subtitle: '官方服务不可达时自动平滑切换备用接口或图片加速节点',
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '代理模式',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: tokens.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  KonataSegmentedCapsule<ProxyMode>(
                    selected: _proxyMode,
                    onChanged: (mode) {
                      setState(() {
                        _proxyMode = mode;
                      });
                    },
                    options: const [
                      KonataSegmentOption(
                        value: ProxyMode.system,
                        label: '跟随系统',
                      ),
                      KonataSegmentOption(
                        value: ProxyMode.custom,
                        label: '自定义代理',
                      ),
                      KonataSegmentOption(
                        value: ProxyMode.none,
                        label: '强制直连',
                      ),
                    ],
                  ),
                  if (_proxyMode == ProxyMode.custom) ...[
                    const SizedBox(height: 12),
                    KonataSoftTextField(
                      controller: _proxyUrlCtrl,
                      hintText: '例如 http://127.0.0.1:7890',
                      prefixIcon: Icons.lan_outlined,
                    ),
                  ],
                  const SizedBox(height: 14),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      setState(() {
                        _showAdvancedMirrors = !_showAdvancedMirrors;
                      });
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Icon(
                            _showAdvancedMirrors
                                ? Icons.expand_less_rounded
                                : Icons.expand_more_rounded,
                            size: 18,
                            color: tokens.accent,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            _showAdvancedMirrors
                                ? '收起备用接口与图片反代地址'
                                : '展开配置备用接口与图片反代地址',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: tokens.accent,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_showAdvancedMirrors) ...[
                    const SizedBox(height: 12),
                    _MirrorInputPair(
                      label: 'TMDB 备用 API 地址',
                      controller: _tmdbBackupApiCtrl,
                    ),
                    _MirrorInputPair(
                      label: 'TMDB 备用图片地址',
                      controller: _tmdbBackupImageCtrl,
                    ),
                    _MirrorInputPair(
                      label: 'Bangumi 公开元数据备用接口（仅无凭据元数据读取）',
                      controller: _bangumiBackupApiCtrl,
                    ),
                    _MirrorInputPair(
                      label: 'Bangumi 备用封面图片地址',
                      controller: _bangumiBackupImageCtrl,
                    ),
                    _MirrorInputPair(
                      label: 'Fanart 备用 API 地址',
                      controller: _fanartBackupApiCtrl,
                    ),
                    _MirrorInputPair(
                      label: 'Fanart 备用图片地址',
                      controller: _fanartBackupImageCtrl,
                    ),
                  ],
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    children: [
                      KonataPillButton.primary(
                        label: saving ? '保存中...' : '保存网络配置',
                        icon: Icons.save_outlined,
                        compact: true,
                        onPressed: saving ? null : _onSave,
                      ),
                      KonataPillButton.secondary(
                        label: '恢复默认镜像与代理',
                        icon: Icons.restore_rounded,
                        compact: true,
                        onPressed: saving ? null : _onResetMirrors,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            KonataSurfaceCard(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SettingsSectionHeader(
                    icon: Icons.network_check_rounded,
                    title: '服务连通性探测',
                    subtitle: '按需实测官方节点与备用镜像的可用性及往返延迟',
                  ),
                  const SizedBox(height: 14),
                  for (final item in _probeDefinitions)
                    _ProbeRow(
                      label: item.label,
                      targetId: item.targetId,
                      probing: controller.isProbingTarget(item.targetId),
                      report: controller.probeReports[item.targetId],
                      tokens: tokens,
                      onProbe: () =>
                          controller.runConnectivityProbe(item.targetId),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  static const List<({String targetId, String label})> _probeDefinitions = [
    (targetId: NetworkProbeTargets.tmdbApi, label: 'TMDB 元数据 API'),
    (targetId: NetworkProbeTargets.tmdbImage, label: 'TMDB 海报与剧照 CDN'),
    (targetId: NetworkProbeTargets.bangumiApi, label: 'Bangumi 公开条目 API'),
    (targetId: NetworkProbeTargets.bangumiImage, label: 'Bangumi 封面图片 CDN'),
    (targetId: NetworkProbeTargets.fanartApi, label: 'Fanart 艺术图 API'),
    (targetId: NetworkProbeTargets.fanartImage, label: 'Fanart 艺术图 CDN'),
  ];
}

class _MirrorInputPair extends StatelessWidget {
  const _MirrorInputPair({
    required this.label,
    required this.controller,
  });

  final String label;
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<KonataPalette>()!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 12, color: tokens.textSecondary),
          ),
          const SizedBox(height: 4),
          KonataSoftTextField(
            controller: controller,
            hintText: 'https://...',
            dense: true,
          ),
        ],
      ),
    );
  }
}

class _ProbeRow extends StatelessWidget {
  const _ProbeRow({
    required this.label,
    required this.targetId,
    required this.probing,
    required this.report,
    required this.tokens,
    required this.onProbe,
  });

  final String label;
  final String targetId;
  final bool probing;
  final ConnectivityReport? report;
  final KonataPalette tokens;
  final VoidCallback onProbe;

  @override
  Widget build(BuildContext context) {
    final statusText = report == null
        ? '未检测'
        : report!.reachable
        ? '可达 · ${report!.latencyMs}ms${report!.usedBackup ? '（走备用节点）' : ''}'
        : (report!.errorMessage ?? '不可达');
    final statusColor = report == null
        ? tokens.textMuted
        : report!.reachable
        ? tokens.success
        : tokens.danger;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: tokens.textPrimary,
                  ),
                ),
                Text(
                  statusText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, color: statusColor),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          KonataPillButton.secondary(
            key: ValueKey<String>('probe_$targetId'),
            label: probing ? '探测中...' : '测速',
            compact: true,
            onPressed: probing ? null : onProbe,
          ),
        ],
      ),
    );
  }
}
