import 'dart:async';

import 'package:file_picker/file_picker.dart' show FileType;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/playback/playback_preferences_provider.dart';
import '../../application/providers/desktop_external_tools_providers.dart';
import '../../domain/models/external_player_config.dart';
import '../../domain/repositories/desktop_relay_service.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/adaptive_responsive_row.dart';
import '../widgets/design_system/konata_pill_button.dart';
import '../widgets/design_system/konata_segmented_capsule.dart';
import '../widgets/design_system/konata_soft_text_field.dart';
import '../widgets/design_system/konata_surface_card.dart';
import '../widgets/design_system/konata_system_file_picker.dart';
import '../widgets/design_system/konata_toast.dart';
import '../widgets/playback/konata_foobar_beefweb_dialog.dart';

/// 设置页「外部调用」一级面板：管理外部视频播放器、外部音频播放器与 `foo_beefweb` 同步状态。
class SettingsExternalToolsPanel extends ConsumerStatefulWidget {
  /// 创建外部调用设置面板。
  const SettingsExternalToolsPanel({super.key});

  @override
  ConsumerState<SettingsExternalToolsPanel> createState() =>
      _SettingsExternalToolsPanelState();
}

class _SettingsExternalToolsPanelState
    extends ConsumerState<SettingsExternalToolsPanel> {
  static const double _pathRowControlHeight = 40.0;
  static const double _beefwebRowControlHeight = 38.0;
  static const double _beefwebPortFieldWidth = 112.0;

  final TextEditingController _mpvController = TextEditingController();
  final TextEditingController _potController = TextEditingController();
  final TextEditingController _audioController = TextEditingController();
  final TextEditingController _beefwebPortController = TextEditingController();

  ExternalPlayerKind _preferredVideoKind = ExternalPlayerKind.mpv;
  bool _initialized = false;
  bool _portInitialized = false;
  bool _hasPendingSave = false;
  Timer? _autoSaveTimer;
  Timer? _portSaveTimer;
  DesktopExternalToolsActions? _actions;

  @override
  void dispose() {
    _autoSaveTimer?.cancel();
    _autoSaveTimer = null;
    _portSaveTimer?.cancel();
    _portSaveTimer = null;
    final pendingActions = _actions;
    if (_hasPendingSave && pendingActions != null) {
      _hasPendingSave = false;
      unawaited(pendingActions.saveExternalPlayers(_buildConfigs()));
    }
    _mpvController.dispose();
    _potController.dispose();
    _audioController.dispose();
    _beefwebPortController.dispose();
    super.dispose();
  }

  List<ExternalPlayerConfig> _buildConfigs() {
    final preferPot = _preferredVideoKind == ExternalPlayerKind.potplayer;
    final mpvConfig = ExternalPlayerConfig(
      id: 'player_mpv',
      name: 'MPV 播放器',
      kind: ExternalPlayerKind.mpv,
      executablePath: _mpvController.text.trim(),
      argumentsTemplate: '--force-window=yes {url}',
      isDefault: !preferPot,
    );
    final potConfig = ExternalPlayerConfig(
      id: 'player_potplayer',
      name: 'PotPlayer',
      kind: ExternalPlayerKind.potplayer,
      executablePath: _potController.text.trim(),
      argumentsTemplate: '{url}',
      isDefault: preferPot,
    );
    return [
      if (preferPot) ...[potConfig, mpvConfig] else ...[mpvConfig, potConfig],
      ExternalPlayerConfig(
        id: 'player_audio',
        name: '外部音频播放器',
        kind: ExternalPlayerKind.audioPlayer,
        executablePath: _audioController.text.trim(),
        argumentsTemplate: '{url}',
      ),
    ];
  }

  void _onPreferredVideoKindChanged(ExternalPlayerKind next) {
    if (_preferredVideoKind == next) {
      return;
    }
    setState(() {
      _initialized = true;
      _preferredVideoKind = next;
    });
    unawaited(
      ref
          .read(playbackPreferencesProvider.notifier)
          .setPreferredRelayKindKey(next.name),
    );
    _hasPendingSave = true;
    unawaited(_flushAutoSave());
  }

  void _scheduleAutoSave() {
    _initialized = true;
    _hasPendingSave = true;
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(
      KonataTheme.settingsAutoSaveDebounce,
      () => unawaited(_flushAutoSave()),
    );
  }

  void _schedulePortSave(String rawText) {
    _portSaveTimer?.cancel();
    _portSaveTimer = Timer(KonataTheme.settingsAutoSaveDebounce, () {
      _commitBeefwebPort(rawText);
    });
  }

  void _commitBeefwebPort(String rawText) {
    _portSaveTimer?.cancel();
    _portSaveTimer = null;
    final parsed = int.tryParse(rawText.trim());
    if (parsed == null || parsed < 1 || parsed > 65535) {
      return;
    }
    unawaited(
      ref
          .read(playbackPreferencesProvider.notifier)
          .setFoobarBeefwebPort(parsed)
          .then((_) {
            if (mounted) {
              ref.invalidate(foobarBeefwebStatusProvider);
            }
          }),
    );
  }

  Future<void> _flushAutoSave() async {
    _autoSaveTimer?.cancel();
    _autoSaveTimer = null;
    if (!_hasPendingSave) {
      return;
    }
    final coordinator =
        _actions ??
        (mounted ? ref.read(desktopExternalToolsActionsProvider) : null);
    if (coordinator == null) {
      return;
    }
    _hasPendingSave = false;
    await coordinator.saveExternalPlayers(_buildConfigs());
  }

  Future<void> _pickExecutable(
    TextEditingController target, {
    required String dialogTitle,
  }) async {
    try {
      final picker = ref.read(konataSystemFilePickerProvider);
      final files = await picker.pickFiles(
        dialogTitle: dialogTitle,
        type: FileType.custom,
        allowedExtensions: const ['exe'],
        allowMultiple: false,
      );
      if (!mounted) {
        return;
      }
      final path = files.firstOrNull?.path;
      if (path != null && path.isNotEmpty) {
        _initialized = true;
        target.text = path;
        _hasPendingSave = true;
        await _flushAutoSave();
        if (mounted) {
          setState(() {});
        }
      }
    } catch (e) {
      if (mounted) {
        showKonataToast(context, '打开系统文件选择器失败：$e', isError: true);
      }
    }
  }

  Future<void> _retestFoobarConnection() async {
    await _flushAutoSave();
    _commitBeefwebPort(_beefwebPortController.text);
    ref.invalidate(foobarBeefwebStatusProvider);
    try {
      final snap = await ref.read(foobarBeefwebStatusProvider.future);
      if (!mounted) {
        return;
      }
      final message = switch (snap.state) {
        FoobarComponentState.connected =>
          '已成功连接 foobar2000 (127.0.0.1:${snap.port})',
        FoobarComponentState.installedPendingStart =>
          '已检测到 foo_beefweb 组件，启动 foobar2000 后即可同步进度',
        FoobarComponentState.missingComponent =>
          '尚未检测到 foo_beefweb 组件，请下载安装并重启 foobar2000',
        FoobarComponentState.notFoobar => '当前配置的外部音频程序非 foobar2000',
        FoobarComponentState.unconfigured => '请先指定 foobar2000.exe 可执行文件路径',
      };
      showKonataToast(
        context,
        message,
        isError: snap.state == FoobarComponentState.missingComponent,
      );
    } catch (_) {
      if (mounted) {
        showKonataToast(context, '检测连接失败，请检查端口配置', isError: true);
      }
    }
  }

  bool _looksLikeFoobarPath(String path) {
    final trimmed = path.trim().toLowerCase();
    return trimmed.isEmpty || trimmed.contains('foobar');
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final playersAsync = ref.watch(desktopExternalPlayersProvider);
    final beefwebStatusAsync = ref.watch(foobarBeefwebStatusProvider);
    final prefKindKey = ref.watch(
      playbackPreferencesProvider.select((s) => s.preferredRelayKindKey),
    );
    final savedPort = ref.watch(
      playbackPreferencesProvider.select((s) => s.foobarBeefwebPort),
    );
    final skipPrompt = ref.watch(
      playbackPreferencesProvider.select((s) => s.skipFoobarBeefwebPrompt),
    );
    final prefKind = prefKindKey == ExternalPlayerKind.potplayer.name
        ? ExternalPlayerKind.potplayer
        : ExternalPlayerKind.mpv;
    _actions = ref.read(desktopExternalToolsActionsProvider);

    if (!_portInitialized) {
      _portInitialized = true;
      _beefwebPortController.text = savedPort.toString();
    }

    playersAsync.whenData((players) {
      if (!_initialized) {
        _initialized = true;
        ExternalPlayerKind? dbDefault;
        for (final player in players) {
          switch (player.kind) {
            case ExternalPlayerKind.mpv:
              _mpvController.text = player.executablePath;
              if (player.isDefault) {
                dbDefault = ExternalPlayerKind.mpv;
              }
            case ExternalPlayerKind.potplayer:
              _potController.text = player.executablePath;
              if (player.isDefault) {
                dbDefault = ExternalPlayerKind.potplayer;
              }
            case ExternalPlayerKind.audioPlayer:
              _audioController.text = player.executablePath;
            case ExternalPlayerKind.custom:
              break;
          }
        }
        _preferredVideoKind =
            prefKind == ExternalPlayerKind.potplayer ||
                dbDefault == ExternalPlayerKind.potplayer
            ? ExternalPlayerKind.potplayer
            : ExternalPlayerKind.mpv;
      }
    });

    if (_initialized && !_hasPendingSave && _preferredVideoKind != prefKind) {
      _preferredVideoKind = prefKind;
    }

    final showFoobarSection = _looksLikeFoobarPath(_audioController.text);
    final statusVisual = _resolveFoobarStatusVisual(p, beefwebStatusAsync);

    return Column(
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
                leading: _CardHeaderBlock(
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
                  onChanged: _onPreferredVideoKindChanged,
                ),
              ),
              const SizedBox(height: 16),
              _ExternalPathFieldRow(
                controller: _mpvController,
                label: 'MPV 可执行文件路径',
                hintText: r'C:\Program Files\mpv\mpv.exe',
                icon: Icons.play_circle_outline_rounded,
                controlHeight: _pathRowControlHeight,
                onChanged: (_) => _scheduleAutoSave(),
                onSubmitted: (_) => unawaited(_flushAutoSave()),
                onBrowse: () => _pickExecutable(
                  _mpvController,
                  dialogTitle: '选择 MPV 播放器可执行文件',
                ),
              ),
              const SizedBox(height: 16),
              _ExternalPathFieldRow(
                controller: _potController,
                label: 'PotPlayer 可执行文件路径',
                hintText:
                    r'C:\Program Files\DAUM\PotPlayer\PotPlayerMini64.exe',
                icon: Icons.ondemand_video_rounded,
                controlHeight: _pathRowControlHeight,
                onChanged: (_) => _scheduleAutoSave(),
                onSubmitted: (_) => unawaited(_flushAutoSave()),
                onBrowse: () => _pickExecutable(
                  _potController,
                  dialogTitle: '选择 PotPlayer 可执行文件',
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
              if (showFoobarSection)
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
                  trailing: _FoobarStatusPill(
                    badge: statusVisual.badge,
                    label: statusVisual.badgeLabel,
                    isLoading: beefwebStatusAsync.isLoading,
                  ),
                )
              else
                const _CardHeaderBlock(
                  title: '外部音频播放器',
                  subtitle:
                      '可指定 foobar2000 等外部程序播放 CD 音轨；配合 foo_beefweb 组件即可支持 WebDAV 分轨展开、继承进度与跨轨回写',
                ),
              const SizedBox(height: 16),
              _ExternalPathFieldRow(
                controller: _audioController,
                label: '外部音频播放器路径（CD / 无损可选）',
                hintText: r'C:\Program Files\foobar2000\foobar2000.exe',
                icon: Icons.library_music_outlined,
                controlHeight: _pathRowControlHeight,
                onChanged: (_) {
                  setState(() {});
                  _scheduleAutoSave();
                },
                onSubmitted: (_) => unawaited(_flushAutoSave()),
                onBrowse: () => _pickExecutable(
                  _audioController,
                  dialogTitle: '选择外部音频播放器可执行文件',
                ),
              ),
              if (showFoobarSection) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Divider(height: 1, thickness: 1, color: p.hairline),
                ),
                _FoobarBeefwebSection(
                  visual: statusVisual,
                  portController: _beefwebPortController,
                  controlHeight: _beefwebRowControlHeight,
                  portFieldWidth: _beefwebPortFieldWidth,
                  skipPromptActive: skipPrompt,
                  onPortChanged: _schedulePortSave,
                  onPortSubmitted: _commitBeefwebPort,
                  onRetest: () => unawaited(_retestFoobarConnection()),
                  onResetPromptPreference: () {
                    unawaited(
                      ref
                          .read(playbackPreferencesProvider.notifier)
                          .setSkipFoobarBeefwebPrompt(false),
                    );
                  },
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
  AsyncValue<FoobarComponentStatusSnapshot> statusAsync,
) {
  final snap = statusAsync.value;
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
      detailText:
          '前往官方组件页下载 .fb2k-component 后双击安装并重启 foobar2000，即可解锁分轨与双向进度同步',
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

class _FoobarBeefwebSection extends StatelessWidget {
  const _FoobarBeefwebSection({
    required this.visual,
    required this.portController,
    required this.controlHeight,
    required this.portFieldWidth,
    required this.skipPromptActive,
    required this.onPortChanged,
    required this.onPortSubmitted,
    required this.onRetest,
    required this.onResetPromptPreference,
  });

  final ({
    FoobarComponentState state,
    KonataBadgeColors badge,
    String badgeLabel,
    String detailText,
  })
  visual;
  final TextEditingController portController;
  final double controlHeight;
  final double portFieldWidth;
  final bool skipPromptActive;
  final ValueChanged<String> onPortChanged;
  final ValueChanged<String> onPortSubmitted;
  final VoidCallback onRetest;
  final VoidCallback onResetPromptPreference;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    final leadingInfo = Column(
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
          visual.detailText,
          style: TextStyle(
            color: p.textMuted,
            fontSize: KonataTheme.fontSizeCaption,
            height: 1.4,
          ),
        ),
        if (skipPromptActive &&
            visual.state == FoobarComponentState.missingComponent) ...[
          const SizedBox(height: 8),
          KonataPillButton.ghost(
            label: '恢复播放前提醒',
            icon: Icons.notifications_active_outlined,
            compact: true,
            onPressed: onResetPromptPreference,
          ),
        ],
      ],
    );

    final trailingControls = Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SizedBox(
          width: portFieldWidth,
          child: KonataSoftTextField(
            key: const ValueKey('settings_foobar_beefweb_port_field'),
            controller: portController,
            hintText: '8880',
            prefixIcon: Icons.lan_outlined,
            height: controlHeight,
            keyboardType: TextInputType.number,
            onChanged: onPortChanged,
            onSubmitted: onPortSubmitted,
          ),
        ),
        KonataPillButton.secondary(
          key: const ValueKey('settings_foobar_beefweb_retest_button'),
          label: '检测连接',
          icon: Icons.sync_rounded,
          compact: true,
          height: controlHeight,
          onPressed: onRetest,
        ),
        KonataPillButton.secondary(
          key: const ValueKey('settings_foobar_beefweb_download_button'),
          label: '前往官方组件页下载',
          icon: Icons.open_in_browser_rounded,
          compact: true,
          height: controlHeight,
          onPressed: () =>
              unawaited(openOfficialFoobarBeefwebDownload(context)),
        ),
      ],
    );

    return KeyedSubtree(
      key: const ValueKey('settings_foobar_beefweb_card'),
      child: AdaptiveResponsiveRow(
        estimatedTrailingWidth: 404,
        minLeadingWidth: 210,
        horizontalGap: 16,
        verticalGap: 12,
        rowCrossAxisAlignment: CrossAxisAlignment.center,
        stackedTrailingAlignment: Alignment.centerLeft,
        leading: leadingInfo,
        trailing: trailingControls,
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
