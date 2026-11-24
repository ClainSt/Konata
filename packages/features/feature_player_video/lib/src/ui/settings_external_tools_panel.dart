import 'dart:async';

import 'package:engine_playback/engine_playback.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/video_playback_preferences.dart';
import '../providers.dart';

/// 桌面外置播放器配置与控制组件引导操作结果。
enum FoobarGuideDialogAction {
  /// 取消关闭窗口。
  cancel,

  /// 已打开浏览器前往官方组件下载页面。
  openedDownloadPage,

  /// 跳过指引并直接执行单向命令行播片。
  skipAndLaunchSingleWay,
}

/// 桌面端专属设置「外部工具」一级面板：管理外部音视频播放器路径与实时同步组件状态。
class SettingsExternalToolsPanel extends ConsumerStatefulWidget {
  /// 创建外部调用工具设置面板。
  const SettingsExternalToolsPanel({
    super.key,
    this.externalPlayerStore,
    this.desktopRelayGateway,
    this.preferencesStore,
    this.urlOpener,
    this.pickExecutableFile,
  });

  /// 可选显式注入的外部播放器持久化存取器。
  final DesktopExternalPlayerStore? externalPlayerStore;

  /// 可选显式注入的桌面外部接力网关。
  final DesktopRelayGateway? desktopRelayGateway;

  /// 可选显式注入的视频偏好存储仓储。
  final VideoPlaybackPreferencesStore? preferencesStore;

  /// 可选显式注入的系统浏览器链接打开端口。
  final UrlOpenerPort? urlOpener;

  /// 可选显式注入的可执行文件选择回调。
  final Future<String?> Function({String? dialogTitle})? pickExecutableFile;

  @override
  ConsumerState<SettingsExternalToolsPanel> createState() =>
      _SettingsExternalToolsPanelState();
}

class _SettingsExternalToolsPanelState
    extends ConsumerState<SettingsExternalToolsPanel> {
  static const double _rowControlHeight = 40.0;

  final TextEditingController _mpvController = TextEditingController();
  final TextEditingController _potController = TextEditingController();
  final TextEditingController _audioController = TextEditingController();
  final TextEditingController _beefwebPortController = TextEditingController();

  ExternalPlayerKind _preferredVideoKind = ExternalPlayerKind.mpv;
  FoobarComponentStatusSnapshot? _probeSnapshot;
  bool _probing = false;
  bool _initialized = false;
  Timer? _autoSaveTimer;

  DesktopExternalPlayerStore? _resolvePlayerStore() {
    if (widget.externalPlayerStore != null) return widget.externalPlayerStore;
    final deps = ref.watch(featurePlayerVideoDependenciesProvider);
    return deps.externalPlayerStore ??
        SqliteDesktopExternalPlayerStore(deps.databases.userState.engine);
  }

  DesktopRelayGateway? _resolveRelayGateway() =>
      widget.desktopRelayGateway ??
      ref.read(featurePlayerVideoDependenciesProvider).desktopRelayGateway;

  VideoPlaybackPreferencesStore _resolvePrefsStore() =>
      widget.preferencesStore ??
      ref.watch(videoPlaybackPreferencesStoreProvider);

  UrlOpenerPort _resolveUrlOpener() =>
      widget.urlOpener ??
      ref.read(featurePlayerVideoDependenciesProvider).urlOpener;

  Future<String?> Function({String? dialogTitle})? _resolveExePicker() =>
      widget.pickExecutableFile ??
      ref.read(featurePlayerVideoDependenciesProvider).pickExecutableFile;

  @override
  void initState() {
    super.initState();
    _beefwebPortController.text = '${FoobarBeefwebConfig.defaultPort}';
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_loadConfigs());
      }
    });
  }

  @override
  void dispose() {
    _autoSaveTimer?.cancel();
    _mpvController.dispose();
    _potController.dispose();
    _audioController.dispose();
    _beefwebPortController.dispose();
    super.dispose();
  }

  Future<void> _loadConfigs() async {
    final store = _resolvePlayerStore();
    if (store == null) return;
    final items = await store.getExternalPlayers();
    if (!mounted) return;

    ExternalPlayerConfig? mpvCfg;
    ExternalPlayerConfig? potCfg;
    ExternalPlayerConfig? audioCfg;
    for (final item in items) {
      if (item.kind == ExternalPlayerKind.mpv) {
        mpvCfg = item;
      } else if (item.kind == ExternalPlayerKind.potplayer) {
        potCfg = item;
      } else if (item.kind == ExternalPlayerKind.audioPlayer) {
        audioCfg = item;
      }
    }

    setState(() {
      _initialized = true;
      _mpvController.text = mpvCfg?.executablePath ?? '';
      _potController.text = potCfg?.executablePath ?? '';
      _audioController.text = audioCfg?.executablePath ?? '';
      _preferredVideoKind = (potCfg?.isDefault == true)
          ? ExternalPlayerKind.potplayer
          : ExternalPlayerKind.mpv;
    });
  }

  List<ExternalPlayerConfig> _buildConfigs() {
    final preferPot = _preferredVideoKind == ExternalPlayerKind.potplayer;
    return <ExternalPlayerConfig>[
      ExternalPlayerConfig(
        id: 'player_mpv',
        name: 'MPV 播放器',
        kind: ExternalPlayerKind.mpv,
        executablePath: _mpvController.text.trim(),
        argumentsTemplate: '--force-window=yes {url}',
        isDefault: !preferPot,
      ),
      ExternalPlayerConfig(
        id: 'player_potplayer',
        name: 'PotPlayer',
        kind: ExternalPlayerKind.potplayer,
        executablePath: _potController.text.trim(),
        argumentsTemplate: '{url}',
        isDefault: preferPot,
      ),
      ExternalPlayerConfig(
        id: 'player_audio',
        name: '外部音频播放器',
        kind: ExternalPlayerKind.audioPlayer,
        executablePath: _audioController.text.trim(),
        argumentsTemplate: '{url}',
      ),
    ];
  }

  void _scheduleSave() {
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(const Duration(milliseconds: 400), () {
      unawaited(_persistNow());
    });
  }

  Future<void> _persistNow() async {
    final store = _resolvePlayerStore();
    if (store == null) return;
    for (final cfg in _buildConfigs()) {
      await store.upsertExternalPlayer(cfg);
    }
  }

  Future<void> _browseExeFor(
    TextEditingController controller,
    String title,
  ) async {
    final picker = _resolveExePicker();
    if (picker == null) {
      if (mounted) {
        showKonataToast(context, '请直接填入外部播放器可执行文件完整路径');
      }
      return;
    }
    final selected = await picker(dialogTitle: title);
    if (!mounted || selected == null || selected.trim().isEmpty) return;
    setState(() => controller.text = selected.trim());
    await _persistNow();
  }

  Future<void> _probeBeefweb() async {
    if (_probing) return;
    setState(() => _probing = true);
    try {
      await _persistNow();
      final relay = _resolveRelayGateway();
      if (relay == null) {
        if (mounted) {
          showKonataToast(context, '未注入桌面外部接力服务，无法检测组件', isError: true);
        }
        return;
      }
      final port =
          int.tryParse(_beefwebPortController.text.trim()) ??
          FoobarBeefwebConfig.defaultPort;
      final snap = await relay.probeAudioPlayerStatus(beefwebPort: port);
      if (mounted) {
        setState(() => _probeSnapshot = snap);
      }
    } finally {
      if (mounted) {
        setState(() => _probing = false);
      }
    }
  }

  Future<void> _showBeefwebGuideDialog(BuildContext context) async {
    final urlOpener = _resolveUrlOpener();
    final prefsStore = _resolvePrefsStore();
    final action = await showKonataGlassDialog<FoobarGuideDialogAction>(
      context: context,
      builder: (dialogCtx) {
        final p = dialogCtx.palette;
        return KonataGlassDialog(
          key: const ValueKey('foobar_beefweb_guide_dialog'),
          width: 460,
          title: '启用 foobar2000 分轨与进度同步',
          onClose: () =>
              Navigator.of(dialogCtx).pop(FoobarGuideDialogAction.cancel),
          actions: [
            KonataPillButton.ghost(
              compact: true,
              label: '仅单文件播放（不再提示）',
              onPressed: () => Navigator.of(
                dialogCtx,
              ).pop(FoobarGuideDialogAction.skipAndLaunchSingleWay),
            ),
            KonataPillButton.primary(
              compact: true,
              icon: Icons.open_in_browser_rounded,
              label: '前往官方组件页下载',
              onPressed: () async {
                final uri = Uri.parse(FoobarBeefwebConfig.officialDownloadUrl);
                final opened = await urlOpener.openExternalUrl(uri);
                if (dialogCtx.mounted) {
                  if (!opened) {
                    showKonataToast(
                      dialogCtx,
                      '请手动访问：${FoobarBeefwebConfig.officialDownloadUrl}',
                      isError: true,
                    );
                  }
                  Navigator.of(
                    dialogCtx,
                  ).pop(FoobarGuideDialogAction.openedDownloadPage);
                }
              },
            ),
          ],
          child: Text(
            '检测到外接音频播放器尚未装配远程控制插件，安装后即可在外部播放期间实时同步当前曲目与分轨播放进度。',
            style: TextStyle(color: p.textSecondary, fontSize: 13, height: 1.5),
          ),
        );
      },
    );
    if (action == FoobarGuideDialogAction.skipAndLaunchSingleWay) {
      prefsStore.setSkipFoobarBeefwebGuidePrompt(true);
    }
  }

  String _formatProbeStatus(FoobarComponentStatusSnapshot snapshot) {
    return switch (snapshot.state) {
      FoobarComponentState.connected => '同步组件已就绪并在本地端口 ${snapshot.port} 连通',
      FoobarComponentState.installedPendingStart =>
        '已检测到远程同步组件（端口 ${snapshot.port}），随播放器启动后即可自动连接',
      FoobarComponentState.missingComponent =>
        '已定位音频播放器，但尚未检测到 foo_beefweb 远程控制组件',
      FoobarComponentState.notFoobar => '当前配置的程序为独立播放器，无需同步组件',
      FoobarComponentState.unconfigured => '尚未配置外部音频播放器可执行文件路径',
    };
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    return Column(
      key: const ValueKey('settings_external_tools_panel'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KonataSurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '桌面外部视频播放器接力路径',
                style: KonataTheme.cardTitleStyle(p),
              ),
              const SizedBox(height: 12),
              AdaptiveSettingTile(
                title: '默认接力视频播放器',
                subtitle: '触发外部播片时优先拉起的桌面程序',
                estimatedTrailingWidth: 240,
                trailing: KonataSegmentedCapsule<ExternalPlayerKind>(
                  compact: true,
                  selected: _preferredVideoKind,
                  options: const [
                    KonataSegmentOption(
                      value: ExternalPlayerKind.mpv,
                      label: 'MPV 播放器',
                    ),
                    KonataSegmentOption(
                      value: ExternalPlayerKind.potplayer,
                      label: 'PotPlayer',
                    ),
                  ],
                  onChanged: (next) {
                    setState(() => _preferredVideoKind = next);
                    unawaited(_persistNow());
                  },
                ),
              ),
              const SizedBox(height: 8),
              _PathInputRow(
                label: 'MPV 可执行文件路径',
                controller: _mpvController,
                hintText: '例如：C:\\Tools\\mpv\\mpv.exe',
                onChanged: (_) => _scheduleSave(),
                onBrowse: () => unawaited(
                  _browseExeFor(_mpvController, '选择 MPV 可执行文件'),
                ),
              ),
              const SizedBox(height: 10),
              _PathInputRow(
                label: 'PotPlayer 可执行文件路径',
                controller: _potController,
                hintText: '例如：C:\\Program Files\\DAUM\\PotPlayer\\PotPlayerMini64.exe',
                onChanged: (_) => _scheduleSave(),
                onBrowse: () => unawaited(
                  _browseExeFor(_potController, '选择 PotPlayer 可执行文件'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: KonataAdaptiveTokens.settingsGap),
        KonataSurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '外部无损音频工具与分轨进度同步',
                style: KonataTheme.cardTitleStyle(p),
              ),
              const SizedBox(height: 12),
              _PathInputRow(
                label: '外部音频播放器可执行文件路径',
                controller: _audioController,
                hintText: '例如：C:\\Program Files\\foobar2000\\foobar2000.exe',
                onChanged: (_) => _scheduleSave(),
                onBrowse: () => unawaited(
                  _browseExeFor(_audioController, '选择外部音频播放器可执行文件'),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  SizedBox(
                    width: 112,
                    child: KonataSoftTextField(
                      controller: _beefwebPortController,
                      label: '同步端口',
                      hintText: '${FoobarBeefwebConfig.defaultPort}',
                      dense: true,
                      height: _rowControlHeight,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Padding(
                    padding: const EdgeInsets.only(top: 18),
                    child: Wrap(
                      spacing: 8,
                      children: [
                        KonataPillButton.secondary(
                          compact: true,
                          height: _rowControlHeight,
                          label: _probing ? '检测中…' : '检测同步组件状态',
                          onPressed: _probing ? null : _probeBeefweb,
                        ),
                        KonataPillButton.ghost(
                          compact: true,
                          height: _rowControlHeight,
                          label: '安装指引',
                          onPressed: () =>
                              unawaited(_showBeefwebGuideDialog(context)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (_probeSnapshot != null) ...[
                const SizedBox(height: 8),
                Text(
                  _formatProbeStatus(_probeSnapshot!),
                  style: TextStyle(
                    color: _probeSnapshot!.isBeefwebReady
                        ? p.accent
                        : p.textSecondary,
                    fontSize: 12.5,
                  ),
                ),
              ] else if (_initialized) ...[
                const SizedBox(height: 6),
                Text(
                  '修改路径后将自动保存至当前本机环境配置。',
                  style: TextStyle(color: p.textMuted, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _PathInputRow extends StatelessWidget {
  const _PathInputRow({
    required this.label,
    required this.controller,
    required this.hintText,
    required this.onChanged,
    required this.onBrowse,
  });

  final String label;
  final TextEditingController controller;
  final String hintText;
  final ValueChanged<String> onChanged;
  final VoidCallback onBrowse;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: KonataSoftTextField(
            controller: controller,
            label: label,
            hintText: hintText,
            dense: true,
            height: 40.0,
            onChanged: onChanged,
          ),
        ),
        const SizedBox(width: 8),
        KonataPillButton.secondary(
          compact: true,
          height: 40.0,
          label: '选择程序',
          onPressed: onBrowse,
        ),
      ],
    );
  }
}
