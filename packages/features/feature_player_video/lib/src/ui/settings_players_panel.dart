import 'dart:async';

import 'package:engine_playback/engine_playback.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/shader_discovery_service.dart';
import '../data/video_playback_preferences.dart';
import '../providers.dart';

/// 设置页「播放与解码」跨平台统一设置面板（全端共用，支持着色器与发烧音频安全策略）。
class SettingsPlayersPanel extends ConsumerStatefulWidget {
  /// 创建播放器与画质偏好设置面板。
  const SettingsPlayersPanel({
    super.key,
    this.preferencesStore,
    this.shaderDiscoveryService,
    this.audiophileCoordinator,
    this.platform,
    this.pickShaderFiles,
  });

  /// 可选显式注入的视频偏好存储仓储。
  final VideoPlaybackPreferencesStore? preferencesStore;

  /// 可选显式注入的着色器目录发现服务。
  final ShaderDiscoveryService? shaderDiscoveryService;

  /// 可选显式注入的发烧音频路由协调器。
  final AudiophileSafetyCoordinator? audiophileCoordinator;

  /// 可选显式注入当前宿主平台。
  final KonataPlatform? platform;

  /// 可选宿主注入的着色器脚本多选回调。
  final Future<List<ShaderImportSource>> Function()? pickShaderFiles;

  @override
  ConsumerState<SettingsPlayersPanel> createState() =>
      _SettingsPlayersPanelState();
}

class _SettingsPlayersPanelState extends ConsumerState<SettingsPlayersPanel> {
  final TextEditingController _endpointController = TextEditingController();
  bool _endpointSynced = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_resolveShaderService().refresh());
      }
    });
  }

  @override
  void dispose() {
    _endpointController.dispose();
    super.dispose();
  }

  VideoPlaybackPreferencesStore _resolvePrefsStore() =>
      widget.preferencesStore ??
      ref.watch(videoPlaybackPreferencesStoreProvider);

  ShaderDiscoveryService _resolveShaderService() =>
      widget.shaderDiscoveryService ??
      ref.watch(videoShaderDiscoveryServiceProvider);

  KonataPlatform _resolvePlatform() =>
      widget.platform ??
      ref.watch(featurePlayerVideoDependenciesProvider).platform;

  Future<List<ShaderImportSource>> Function()? _resolveShaderPicker() =>
      widget.pickShaderFiles ??
      (widget.preferencesStore == null
          ? ref.read(featurePlayerVideoDependenciesProvider).pickShaderFiles
          : null);

  Future<void> _handleImportShaders(BuildContext context) async {
    final picker = _resolveShaderPicker();
    if (picker == null) {
      showKonataToast(context, '请将自定义着色器脚本放入用户着色器目录后刷新');
      await _resolveShaderService().refresh();
      return;
    }
    final files = await picker();
    if (!context.mounted || files.isEmpty) return;
    final result = await _resolveShaderService().importShaderFiles(files);
    if (!context.mounted) return;
    showKonataToast(
      context,
      '已导入 ${result.imported.length} 个着色器（跳过 ${result.skippedUnsupported} 个）',
    );
  }

  Future<void> _showUnlockAudiophileDialog(
    BuildContext context,
    VideoPlaybackPreferences prefs,
  ) async {
    final coordinator = widget.audiophileCoordinator;
    if (coordinator == null) {
      showKonataToast(context, '当前环境未挂载硬件音频路由协调器');
      return;
    }
    final routeMode = coordinator.resolveRouteMode(prefs.audiophilePreferences);
    final canProbe =
        routeMode == AudioOutputRouteMode.exclusiveAudioOutput ||
        routeMode == AudioOutputRouteMode.androidBitPerfectUsb;

    final confirmed = await showKonataGlassDialog<bool>(
      context: context,
      builder: (dialogCtx) {
        String? probeNotice;
        var probing = false;
        return StatefulBuilder(
          builder: (innerCtx, setDialogState) {
            final p = innerCtx.palette;
            final verified =
                coordinator.deviceSafetyState.isBackendMeterVerified;
            return KonataGlassDialog(
              title: '当次会话满幅输出安全确认',
              width: 460,
              actions: [
                KonataPillButton.ghost(
                  label: '保持安全限幅',
                  onPressed: () => Navigator.of(dialogCtx).pop(false),
                ),
                if (!verified && canProbe)
                  KonataPillButton.ghost(
                    label: probing ? '检测中…' : '检测直通链路',
                    onPressed: probing
                        ? null
                        : () async {
                            setDialogState(() {
                              probing = true;
                              probeNotice = null;
                            });
                            final res = await coordinator.verifyActiveHardwareRoute(
                              prefs.audiophilePreferences,
                            );
                            if (dialogCtx.mounted) {
                              setDialogState(() {
                                probing = false;
                                probeNotice = res.detail;
                              });
                            }
                          },
                  ),
                KonataPillButton.primary(
                  label: verified ? '确认解锁本次满幅' : '验证门锁状态',
                  onPressed: () => Navigator.of(dialogCtx).pop(true),
                ),
              ],
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    verified
                        ? '当前外设已完成直通核验，确认后将仅对本次会话解锁安全限幅。'
                        : '${AudiophileSafetyPolicy.unverifiedFullScaleLockReason}。',
                    style: TextStyle(color: p.textSecondary, fontSize: 13),
                  ),
                  if (probeNotice != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      probeNotice!,
                      style: TextStyle(color: p.accent, fontSize: 12),
                    ),
                  ],
                ],
              ),
            );
          },
        );
      },
    );

    if (confirmed == true && context.mounted) {
      final unlocked = await coordinator.confirmSessionFullScaleUnlock(
        prefs.audiophilePreferences,
      );
      if (!context.mounted) return;
      showKonataToast(
        context,
        unlocked
            ? '已核验硬件直通链路并解锁本次会话满幅输出'
            : AudiophileSafetyPolicy.unverifiedFullScaleLockReason,
        isError: !unlocked,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final store = _resolvePrefsStore();
    final shaderService = _resolveShaderService();
    final platform = _resolvePlatform();

    return StreamBuilder<VideoPlaybackPreferences>(
      initialData: store.read(),
      stream: store.watch(),
      builder: (context, snapshot) {
        final prefs = snapshot.data ?? store.read();
        final quality = prefs.qualityConfig;
        if (!_endpointSynced) {
          _endpointSynced = true;
          _endpointController.text = prefs.fontInAssEndpoint;
        }

        return Column(
          key: const ValueKey('settings_players_panel'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            KonataSurfaceCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '默认播放内核与自动化行为',
                    style: KonataTheme.cardTitleStyle(p),
                  ),
                  const SizedBox(height: 12),
                  if (platform == KonataPlatform.windows)
                    AdaptiveSettingTile(
                      title: '默认视频播放引擎',
                      subtitle: '选择默认在应用内全屏舞台播片或交由外置工具接力',
                      estimatedTrailingWidth: 260,
                      trailing: KonataSegmentedCapsule<PreferredPlaybackEngine>(
                        compact: true,
                        selected: prefs.preferredEngine,
                        options: const [
                          KonataSegmentOption(
                            value: PreferredPlaybackEngine.builtinLibmpv,
                            label: '内置播放器',
                          ),
                          KonataSegmentOption(
                            value: PreferredPlaybackEngine.desktopRelay,
                            label: '外部播放器',
                          ),
                        ],
                        onChanged: store.setPreferredEngine,
                      ),
                    ),
                  AdaptiveSettingTile(
                    title: '正片完播自动连播下一集',
                    subtitle: '当前剧集自然播放结束后短暂提示并切换下一集',
                    trailing: KonataSwitch(
                      key: const ValueKey('settings_auto_next_switch'),
                      value: prefs.autoPlayNextEpisode,
                      onChanged: store.setAutoPlayNextEpisode,
                    ),
                  ),
                  AdaptiveSettingTile(
                    title: '自动跳过显式命名片头与片尾',
                    subtitle: '仅对媒体明确标注片头或片尾名称的章节执行自动跳转',
                    trailing: KonataSwitch(
                      key: const ValueKey('settings_auto_skip_switch'),
                      value: prefs.autoSkipChapters,
                      onChanged: store.setAutoSkipChapters,
                    ),
                  ),
                  AdaptiveSettingTile(
                    title: '画质缩放滤镜档位',
                    subtitle: '平衡高保真动漫锐化还原与设备渲染功耗',
                    estimatedTrailingWidth: 240,
                    trailing: KonataDropdown<VideoQualityPreset>(
                      value: quality.preset,
                      options: [
                        for (final preset in VideoQualityPreset.values)
                          KonataDropdownOption(
                            value: preset,
                            label: preset.label,
                          ),
                      ],
                      onChanged: (next) => store.updateQualityConfig(
                        (q) => q.copyWith(preset: next),
                      ),
                    ),
                  ),
                  if (platform == KonataPlatform.windows)
                    AdaptiveSettingTile(
                      title: '桌面端视频渲染管线',
                      subtitle: '优先高色深共享纹理同层合成，兼顾高动态范围自动升档',
                      estimatedTrailingWidth: 260,
                      trailing: KonataDropdown<VideoOutputPipelineMode>(
                        value: quality.outputPipelineMode,
                        options: [
                          for (final mode in VideoOutputPipelineMode.values)
                            KonataDropdownOption(
                              value: mode,
                              label: mode.label,
                            ),
                        ],
                        onChanged: (next) => store.updateQualityConfig(
                          (q) => q.copyWith(outputPipelineMode: next),
                        ),
                      ),
                    ),
                  AdaptiveSettingTile(
                    title: '硬件加速解码',
                    subtitle: '高危高比特深度流自动介入多线程软解防花屏保护',
                    trailing: KonataSwitch(
                      key: const ValueKey('settings_hwdec_switch'),
                      value: quality.hardwareDecode,
                      onChanged: (val) => store.updateQualityConfig(
                        (q) => q.copyWith(hardwareDecode: val),
                      ),
                    ),
                  ),
                  AdaptiveSettingTile(
                    title: '实时画面去色带',
                    subtitle: '平滑暗场景压制产生的色彩断层阶梯',
                    trailing: KonataSwitch(
                      key: const ValueKey('settings_deband_switch'),
                      value: quality.debandEnabled,
                      onChanged: (val) => store.updateQualityConfig(
                        (q) => q.copyWith(debandEnabled: val),
                      ),
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
                    '高精度音频输出与安全保护',
                    style: KonataTheme.cardTitleStyle(p),
                  ),
                  const SizedBox(height: 12),
                  if (platform == KonataPlatform.windows)
                    AdaptiveSettingTile(
                      title: '桌面音频设备独占输出',
                      subtitle: '绕过系统混音器以原采样率直达声卡或外置解码器',
                      trailing: KonataSwitch(
                        value: quality.exclusiveAudioOutput,
                        onChanged: (val) => store.updateQualityConfig(
                          (q) => q.copyWith(exclusiveAudioOutput: val),
                        ),
                      ),
                    ),
                  if (platform == KonataPlatform.windows)
                    AdaptiveSettingTile(
                      title: '压缩音频源码直通',
                      subtitle: '透传未解码多声道音轨至功放设备，关闭内置音量调节',
                      trailing: KonataSwitch(
                        value: prefs.bitstreamPassthrough,
                        onChanged: (val) =>
                            store.setAudiophileFlags(bitstreamPassthrough: val),
                      ),
                    ),
                  if (platform != KonataPlatform.windows)
                    AdaptiveSettingTile(
                      title: '外接便携解码器逐位直通',
                      subtitle: '自动协商便携设备硬件原生采样率输出',
                      trailing: KonataSwitch(
                        value: prefs.androidBitPerfectUsb,
                        onChanged: (val) =>
                            store.setAudiophileFlags(androidBitPerfectUsb: val),
                      ),
                    ),
                  if (widget.audiophileCoordinator != null)
                    AdaptiveSettingTile(
                      title: '防爆音满幅输出锁状态',
                      subtitle: '更换外设时自动限幅以保护听力，确认核验后可解锁当次会话',
                      trailing: KonataPillButton.secondary(
                        compact: true,
                        label: '核验与解锁',
                        onPressed: () =>
                            unawaited(_showUnlockAudiophileDialog(context, prefs)),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: KonataAdaptiveTokens.settingsGap),
            KonataSurfaceCard(
              child: ListenableBuilder(
                listenable: shaderService,
                builder: (context, _) {
                  final shaderState = shaderService.state;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AdaptiveResponsiveRow(
                        leading: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '自定义渲染着色器脚本',
                              style: KonataTheme.cardTitleStyle(p),
                            ),
                            if (shaderState.directoryPath != null)
                              Text(
                                '目录: ${shaderState.directoryPath}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: p.textMuted,
                                  fontSize: 12,
                                ),
                              ),
                          ],
                        ),
                        trailing: Wrap(
                          spacing: 8,
                          children: [
                            KonataPillButton.ghost(
                              compact: true,
                              icon: Icons.refresh_rounded,
                              label: '刷新目录',
                              onPressed: () =>
                                  unawaited(shaderService.refresh()),
                            ),
                            KonataPillButton.secondary(
                              compact: true,
                              icon: Icons.add_rounded,
                              label: '导入着色器',
                              onPressed: () =>
                                  unawaited(_handleImportShaders(context)),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      if (shaderState.files.isEmpty)
                        Text(
                          '当前目录暂未扫描到可用着色器脚本文件。',
                          style: TextStyle(color: p.textMuted, fontSize: 12.5),
                        )
                      else
                        for (final entry in shaderState.files)
                          AdaptiveSettingTile(
                            title: entry.name,
                            subtitle: entry.path,
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                KonataSwitch(
                                  value: quality.activeShaderPaths.contains(
                                    entry.path,
                                  ),
                                  onChanged: (enabled) => store
                                      .toggleShaderPath(entry.path, enabled),
                                ),
                                const SizedBox(width: 6),
                                KonataCapsuleIconButton(
                                  icon: Icons.delete_outline_rounded,
                                  tooltip: '删除着色器',
                                  size: 18,
                                  color: p.danger,
                                  onTap: () => unawaited(
                                    shaderService.deleteShaderFile(entry.path),
                                  ),
                                ),
                              ],
                            ),
                          ),
                    ],
                  );
                },
              ),
            ),
            const SizedBox(height: KonataAdaptiveTokens.settingsGap),
            KonataSurfaceCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '云端字幕字体子集化（可选按域授权）',
                    style: KonataTheme.cardTitleStyle(p),
                  ),
                  const SizedBox(height: 12),
                  AdaptiveSettingTile(
                    title: '启用外挂字幕云端字体子集化',
                    subtitle: '在原文字幕缺失内嵌字库时按需生成轻量化字体对比轨道',
                    trailing: KonataSwitch(
                      value: prefs.enableCloudSubset,
                      onChanged: (enabled) => store.updateCloudSubsetSettings(
                        enabled: enabled,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: KonataSoftTextField(
                          controller: _endpointController,
                          hintText: '输入服务端接口地址',
                          dense: true,
                          height: 40,
                          onSubmitted: (val) => store.updateCloudSubsetSettings(
                            endpointUrl: val.trim(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      KonataPillButton.secondary(
                        compact: true,
                        height: 40,
                        label: '授权来源',
                        onPressed: () {
                          final raw = _endpointController.text.trim();
                          final uri = Uri.tryParse(raw);
                          if (uri == null || uri.host.isEmpty) {
                            showKonataToast(
                              context,
                              '请输入有效的服务端网络地址',
                              isError: true,
                            );
                            return;
                          }
                          final origin = CloudSubsetOrigin.fromUri(uri);
                          store.updateCloudSubsetSettings(endpointUrl: raw);
                          store.authorizeCloudSubsetOrigin(origin.key);
                          showKonataToast(context, '已授权来源 ${origin.key}');
                        },
                      ),
                    ],
                  ),
                  if (prefs.authorizedCloudSubsetOrigins.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    for (final origin in prefs.authorizedCloudSubsetOrigins)
                      AdaptiveSettingTile(
                        title: origin,
                        trailing: KonataPillButton.ghost(
                          compact: true,
                          label: '撤销授权',
                          onPressed: () =>
                              store.revokeCloudSubsetOrigin(origin),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
