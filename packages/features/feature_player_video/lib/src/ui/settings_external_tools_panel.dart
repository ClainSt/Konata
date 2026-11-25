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

/// 桌面端专属设置「外部调用」一级面板：管理外部音视频播放器路径与实时同步组件状态。
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
  Timer? _autoSaveTimer;

  DesktopExternalPlayerStore? _resolvePlayerStore() {
    if (widget.externalPlayerStore != null) return widget.externalPlayerStore;
    final deps = ref.read(featurePlayerVideoDependenciesProvider);
    return deps.externalPlayerStore ??
        SqliteDesktopExternalPlayerStore(deps.databases.userState.engine);
  }

  DesktopRelayGateway? _resolveRelayGateway() =>
      widget.desktopRelayGateway ??
      ref.read(featurePlayerVideoDependenciesProvider).desktopRelayGateway;

  VideoPlaybackPreferencesStore _resolvePrefsStore() =>
      widget.preferencesStore ??
      ref.read(videoPlaybackPreferencesStoreProvider);

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
      _mpvController.text = mpvCfg?.executablePath ?? '';
      _potController.text = potCfg?.executablePath ?? '';
      _audioController.text = audioCfg?.executablePath ?? '';
      _preferredVideoKind = (potCfg?.isDefault == true)
          ? ExternalPlayerKind.potplayer
          : ExternalPlayerKind.mpv;
    });
    if (_showFoobarSection && _audioController.text.trim().isNotEmpty) {
      await _probeBeefweb(persist: false);
    }
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

  void _scheduleSave({bool probeAudio = false}) {
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(const Duration(milliseconds: 400), () async {
      await _persistNow();
      if (mounted &&
          probeAudio &&
          _showFoobarSection &&
          _audioController.text.trim().isNotEmpty) {
        await _probeBeefweb(persist: false);
      }
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
    setState(() {
      controller.text = selected.trim();
      if (identical(controller, _audioController)) _probeSnapshot = null;
    });
    await _persistNow();
    if (mounted &&
        identical(controller, _audioController) &&
        _showFoobarSection) {
      await _probeBeefweb(persist: false);
    }
  }

  Future<void> _probeBeefweb({bool persist = true}) async {
    if (_probing || !mounted) return;
    final path = _audioController.text.trim();
    final portText = _beefwebPortController.text.trim();
    final port = int.tryParse(portText);
    if (port == null || port < 1 || port > 65535) {
      showKonataToast(context, '请输入有效的端口号（1–65535）', isError: true);
      return;
    }
    setState(() => _probing = true);
    try {
      if (persist) await _persistNow();
      if (!mounted) return;
      final relay = _resolveRelayGateway();
      if (relay == null) {
        if (mounted) {
          showKonataToast(context, '未注入桌面外部接力服务，无法检测组件', isError: true);
        }
        return;
      }
      final snap = await relay.probeAudioPlayerStatus(beefwebPort: port);
      if (mounted &&
          path == _audioController.text.trim() &&
          portText == _beefwebPortController.text.trim()) {
        setState(() => _probeSnapshot = snap);
      }
    } catch (_) {
      if (mounted) showKonataToast(context, '检测连接失败，请检查播放器和端口', isError: true);
    } finally {
      if (mounted) {
        setState(() => _probing = false);
      }
    }
  }

  Future<void> _openBeefwebDownload() async {
    final opened = await _resolveUrlOpener().openExternalUrl(
      Uri.parse(FoobarBeefwebConfig.officialDownloadUrl),
    );
    if (!opened && mounted) {
      showKonataToast(context, '无法打开官方组件页，请重试', isError: true);
    }
  }

  bool get _showFoobarSection {
    final path = _audioController.text.trim().toLowerCase();
    return path.isEmpty || path.contains('foobar');
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final showFoobarSection = _showFoobarSection;
    final snapshot = _probeSnapshot;
    final status = _resolveFoobarStatusVisual(p, snapshot);
    return Column(
      key: const ValueKey('settings_external_tools_panel'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KonataSurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AdaptiveResponsiveRow(
                estimatedTrailingWidth: 176,
                minLeadingWidth: 180,
                horizontalGap: 16,
                stackedTrailingAlignment: Alignment.centerLeft,
                leading: const _CardHeaderBlock(
                  title: '外部视频播放器与热接力',
                  subtitle: '可在右键菜单、多版本选播或内置播放器顶栏中一键热切换拉起并延续当前秒级进度',
                ),
                trailing: KonataSegmentedCapsule<ExternalPlayerKind>(
                  options: const [
                    KonataSegmentOption(
                      value: ExternalPlayerKind.mpv,
                      label: 'MPV',
                    ),
                    KonataSegmentOption(
                      value: ExternalPlayerKind.potplayer,
                      label: 'PotPlayer',
                    ),
                  ],
                  selected: _preferredVideoKind,
                  onChanged: (next) {
                    setState(() => _preferredVideoKind = next);
                    unawaited(_persistNow());
                  },
                ),
              ),
              const SizedBox(height: 16),
              _ExternalPathFieldRow(
                controller: _mpvController,
                label: 'MPV 可执行文件路径',
                hintText: r'C:\Program Files\mpv\mpv.exe',
                icon: Icons.play_circle_outline_rounded,
                controlHeight: _rowControlHeight,
                onChanged: (_) => _scheduleSave(),
                onSubmitted: (_) => unawaited(_persistNow()),
                onBrowse: () =>
                    unawaited(_browseExeFor(_mpvController, '选择 MPV 可执行文件')),
              ),
              const SizedBox(height: 16),
              _ExternalPathFieldRow(
                controller: _potController,
                label: 'PotPlayer 可执行文件路径',
                hintText:
                    r'C:\Program Files\DAUM\PotPlayer\PotPlayerMini64.exe',
                icon: Icons.ondemand_video_rounded,
                controlHeight: _rowControlHeight,
                onChanged: (_) => _scheduleSave(),
                onSubmitted: (_) => unawaited(_persistNow()),
                onBrowse: () => unawaited(
                  _browseExeFor(_potController, '选择 PotPlayer 可执行文件'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        KonataSurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AdaptiveResponsiveRow(
                estimatedTrailingWidth: 190,
                minLeadingWidth: 180,
                horizontalGap: 16,
                stackedTrailingAlignment: Alignment.centerLeft,
                leading: const _CardHeaderBlock(
                  title: '外部音频播放器',
                  subtitle:
                      '可指定 foobar2000 等外部程序播放 CD 音轨；配合 foo_beefweb 组件即可支持 WebDAV 分轨展开、继承进度与跨轨回写',
                ),
                trailing: showFoobarSection
                    ? _FoobarStatusPill(
                        badge: status.badge,
                        label: status.badgeLabel,
                        isLoading: _probing,
                      )
                    : const SizedBox.shrink(),
              ),
              const SizedBox(height: 16),
              _ExternalPathFieldRow(
                controller: _audioController,
                label: '外部音频播放器路径（CD / 无损可选）',
                hintText: r'C:\Program Files\foobar2000\foobar2000.exe',
                icon: Icons.library_music_outlined,
                controlHeight: _rowControlHeight,
                onChanged: (_) {
                  setState(() => _probeSnapshot = null);
                  _scheduleSave(probeAudio: true);
                },
                onSubmitted: (_) => unawaited(_persistNow()),
                onBrowse: () => unawaited(
                  _browseExeFor(_audioController, '选择外部音频播放器可执行文件'),
                ),
              ),
              if (showFoobarSection) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Divider(height: 1, thickness: 1, color: p.hairline),
                ),
                AdaptiveResponsiveRow(
                  estimatedTrailingWidth: 404,
                  minLeadingWidth: 210,
                  horizontalGap: 16,
                  verticalGap: 12,
                  stackedTrailingAlignment: Alignment.centerLeft,
                  leading: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Beefweb 本地同步端口',
                        style: TextStyle(
                          color: p.textPrimary,
                          fontSize: KonataTheme.fontSizeBodySm,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        status.detailText,
                        style: TextStyle(
                          color: p.textMuted,
                          fontSize: KonataTheme.fontSizeCaption,
                          height: 1.4,
                        ),
                      ),
                      if (_resolvePrefsStore()
                              .read()
                              .skipFoobarBeefwebGuidePrompt &&
                          status.state == FoobarComponentState.missingComponent)
                        KonataPillButton.ghost(
                          label: '恢复播放前提醒',
                          onPressed: () {
                            _resolvePrefsStore()
                                .setSkipFoobarBeefwebGuidePrompt(false);
                            setState(() {});
                          },
                        ),
                    ],
                  ),
                  trailing: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      SizedBox(
                        width: 112,
                        child: KonataSoftTextField(
                          key: const ValueKey(
                            'settings_foobar_beefweb_port_field',
                          ),
                          controller: _beefwebPortController,
                          hintText: '8880',
                          prefixIcon: Icons.lan_outlined,
                          height: 38,
                          keyboardType: TextInputType.number,
                          onChanged: (_) =>
                              setState(() => _probeSnapshot = null),
                        ),
                      ),
                      KonataPillButton.secondary(
                        key: const ValueKey(
                          'settings_foobar_beefweb_retest_button',
                        ),
                        label: _probing ? '检测中…' : '检测连接',
                        icon: Icons.sync_rounded,
                        compact: true,
                        height: 38,
                        onPressed: _probing ? null : _probeBeefweb,
                      ),
                      KonataPillButton.secondary(
                        key: const ValueKey(
                          'settings_foobar_beefweb_download_button',
                        ),
                        label: '前往官方组件页下载',
                        icon: Icons.open_in_browser_rounded,
                        compact: true,
                        height: 38,
                        onPressed: () => unawaited(_openBeefwebDownload()),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _CardHeaderBlock extends StatelessWidget {
  const _CardHeaderBlock({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          style: TextStyle(
            color: p.textPrimary,
            fontSize: KonataTheme.fontSizeTitleSm,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: TextStyle(
            color: p.textSecondary,
            fontSize: KonataTheme.fontSizeBodyXs,
            height: 1.4,
          ),
        ),
      ],
    );
  }
}

({
  FoobarComponentState state,
  KonataBadgeColors badge,
  String badgeLabel,
  String detailText,
})
_resolveFoobarStatusVisual(
  KonataPalette p,
  FoobarComponentStatusSnapshot? snap,
) {
  final state = snap?.state ?? FoobarComponentState.unconfigured;
  final port = snap?.port ?? FoobarBeefwebConfig.defaultPort;
  return switch (state) {
    FoobarComponentState.connected => (
      state: state,
      badge: p.successBadge,
      badgeLabel: '已连接 foo_beefweb ($port)',
      detailText: '已启用 WebDAV 零落盘分轨、专属「Konata」播放列表隔离与秒级双向进度同步',
    ),
    FoobarComponentState.installedPendingStart => (
      state: state,
      badge: p.accentBadge,
      badgeLabel: '已安装 foo_beefweb 组件',
      detailText: '已检测到本地组件文件，启动 foobar2000 时将自动连接 $port 端口同步进度',
    ),
    FoobarComponentState.missingComponent => (
      state: state,
      badge: p.warningBadge,
      badgeLabel: '未检测到 foo_beefweb 组件',
      detailText: '前往官方组件页下载 .fb2k-component 后双击安装并重启 foobar2000，即可解锁分轨与双向进度同步',
    ),
    FoobarComponentState.notFoobar => (
      state: state,
      badge: p.accentBadge,
      badgeLabel: '非 foobar2000 程序',
      detailText: '当前配置为其他外部程序，将按标准命令行或内置协议通道拉起',
    ),
    FoobarComponentState.unconfigured => (
      state: state,
      badge: p.accentBadge,
      badgeLabel: '待配置 foobar2000 路径',
      detailText: '指定 foobar2000.exe 后将自动检测 foo_beefweb 组件与本地同步端口',
    ),
  };
}

class _FoobarStatusPill extends StatelessWidget {
  const _FoobarStatusPill({
    required this.badge,
    required this.label,
    required this.isLoading,
  });

  final KonataBadgeColors badge;
  final String label;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: badge.bg,
        borderRadius: KonataTheme.borderRadiusPill,
        border: Border.all(color: badge.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: badge.fg, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            isLoading ? '正在检测...' : label,
            maxLines: 1,
            softWrap: false,
            style: TextStyle(
              color: badge.fg,
              fontSize: KonataTheme.fontSizeBadge,
              fontWeight: FontWeight.w600,
              height: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}

class _ExternalPathFieldRow extends StatelessWidget {
  const _ExternalPathFieldRow({
    required this.controller,
    required this.label,
    required this.hintText,
    required this.icon,
    required this.controlHeight,
    required this.onChanged,
    required this.onSubmitted,
    required this.onBrowse,
  });

  final TextEditingController controller;
  final String label;
  final String hintText;
  final IconData icon;
  final double controlHeight;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onBrowse;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          label,
          style: TextStyle(
            color: p.textSecondary,
            fontSize: KonataTheme.fontSizeBodyXs,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 6),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: KonataSoftTextField(
                controller: controller,
                hintText: hintText,
                prefixIcon: icon,
                height: controlHeight,
                onChanged: onChanged,
                onSubmitted: onSubmitted,
              ),
            ),
            const SizedBox(width: 10),
            KonataPillButton.secondary(
              label: '浏览',
              height: controlHeight,
              onPressed: onBrowse,
            ),
          ],
        ),
      ],
    );
  }
}
