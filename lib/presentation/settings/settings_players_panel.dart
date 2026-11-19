import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;
import 'package:url_launcher/url_launcher.dart';

import '../../application/playback/playback_preferences_provider.dart';
import '../../domain/playback/ass_semantic_verifier.dart';
import '../../domain/playback/audiophile_safety_policy.dart';
import '../../infrastructure/players/android/android_audio_route_bridge.dart';
import '../../infrastructure/players/mpv_quality_profile.dart';
import '../../infrastructure/storage/storage_root_provider.dart';
import '../theme/konata_adaptive_tokens.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/adaptive_responsive_row.dart';
import '../widgets/design_system/konata_dropdown.dart';
import '../widgets/design_system/konata_pill_button.dart';
import '../widgets/design_system/konata_segmented_capsule.dart';
import '../widgets/design_system/konata_soft_text_field.dart';
import '../widgets/design_system/konata_surface_card.dart';
import '../widgets/design_system/konata_toast.dart';
import '../widgets/playback/konata_spec_badge.dart';

/// 播放器设置面板：
/// 内置 `libmpv` 运行时探针、默认引擎路由、动漫音画精细参数与 `shaders/` 着色器扫描。
class SettingsPlayersPanel extends ConsumerStatefulWidget {
  /// 创建播放与音画还原设置面板。
  const SettingsPlayersPanel({super.key});

  @override
  ConsumerState<SettingsPlayersPanel> createState() =>
      _SettingsPlayersPanelState();
}

class _SettingsPlayersPanelState extends ConsumerState<SettingsPlayersPanel> {
  Directory? _shadersDir;
  List<File> _shaderFiles = const [];
  bool _scanningShaders = false;
  late final TextEditingController _cloudEndpointCtrl;
  final FocusNode _cloudEndpointFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _cloudEndpointCtrl = TextEditingController(
      text: ref.read(playbackPreferencesProvider).cloudSubsetEndpoint,
    );
    _loadShadersSync();
  }

  @override
  void dispose() {
    _cloudEndpointCtrl.dispose();
    _cloudEndpointFocus.dispose();
    super.dispose();
  }

  void _loadShadersSync() {
    try {
      final dir = ref.read(storageRootProvider).resolveShadersDirSync();
      final files = MpvQualityProfile.discoverShaderFilesSync(dir);
      _shadersDir = dir;
      _shaderFiles = files;
    } catch (_) {}
  }

  Future<void> _scanShaders() async {
    if (_scanningShaders) return;
    setState(() => _scanningShaders = true);
    try {
      final dir = ref.read(storageRootProvider).resolveShadersDirSync();
      final files = MpvQualityProfile.discoverShaderFilesSync(dir);
      if (!mounted) return;
      setState(() {
        _shadersDir = dir;
        _shaderFiles = files;
        _scanningShaders = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _scanningShaders = false);
    }
  }

  Future<void> _toggleAndroidBitPerfectUsb(
    bool enabled, {
    required PlaybackPreferencesNotifier notifier,
  }) async {
    await notifier.setAndroidBitPerfectUsb(enabled);
    final res = await AndroidAudioRouteBridge.negotiateBitPerfectUsb(
      enable: enabled,
    );
    if (!mounted) return;
    if (enabled) {
      if (res.engaged) {
        final dev = res.deviceName.isNotEmpty ? res.deviceName : 'USB DAC';
        showKonataToast(context, '已启用逐位直通：$dev');
      } else {
        showKonataToast(
          context,
          res.detail.isNotEmpty
              ? res.detail
              : '未检测到兼容逐位混音器的 USB DAC，已保持高精共享通道',
        );
      }
    } else {
      showKonataToast(context, '已切换回系统高精共享音频输出');
    }
  }

  Future<void> _openShadersFolder() async {
    try {
      final dir =
          _shadersDir ?? await ref.read(storageRootProvider).ensureShadersDir();
      final ok = await launchUrl(
        Uri.file(dir.path),
        mode: LaunchMode.externalApplication,
      );
      if (!ok && mounted) {
        showKonataToast(context, '无法打开着色器目录', isError: true);
      }
    } catch (e) {
      if (mounted) {
        showKonataToast(context, '打开目录失败：$e', isError: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final prefs = ref.watch(playbackPreferencesProvider);
    ref.watch(cloudSubsetAuthRevisionProvider);
    final notifier = ref.read(playbackPreferencesProvider.notifier);
    if (!_cloudEndpointFocus.hasFocus &&
        _cloudEndpointCtrl.text != prefs.cloudSubsetEndpoint) {
      _cloudEndpointCtrl.text = prefs.cloudSubsetEndpoint;
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final videoCard = _buildVideoQualityCard(p, prefs, notifier);
        final audioCard = _buildAudioAndShaderCard(p, prefs, notifier);
        if (constraints.maxWidth >= 780) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: videoCard),
              const SizedBox(width: 16),
              Expanded(child: audioCard),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [videoCard, const SizedBox(height: 16), audioCard],
        );
      },
    );
  }

  Widget _buildVideoQualityCard(
    KonataPalette p,
    PlaybackPreferencesState prefs,
    PlaybackPreferencesNotifier notifier,
  ) {
    final q = prefs.qualityConfig;
    return KonataSurfaceCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '视频渲染与看番体验',
                  style: TextStyle(
                    color: p.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (KonataAdaptiveTokens.isWindows) ...[
                  const SizedBox(height: 12),
                  AdaptiveSettingTile(
                    padding: EdgeInsets.zero,
                    title: '默认视频播放引擎',
                    subtitle: '点击正片或特典卡片时默认打开的播放器；右键卡片可随时临时指定其他播放器',
                    estimatedTrailingWidth: 210,
                    trailing: KonataSegmentedCapsule<PreferredPlaybackEngine>(
                      selected: prefs.defaultVideoEngine,
                      options: const [
                        KonataSegmentOption(
                          value: PreferredPlaybackEngine.builtinLibmpv,
                          label: '内置播放器',
                        ),
                        KonataSegmentOption(
                          value: PreferredPlaybackEngine.externalPlayer,
                          label: '外部播放器',
                        ),
                      ],
                      onChanged: notifier.setDefaultVideoEngine,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Text(
                  '画质与缩放预设',
                  style: TextStyle(color: p.textSecondary, fontSize: 12.5),
                ),
                const SizedBox(height: 6),
                KonataDropdown<VideoQualityPreset>(
                  dense: true,
                  value: q.preset,
                  options: [
                    for (final preset in VideoQualityPreset.values)
                      KonataDropdownOption(value: preset, label: preset.label),
                  ],
                  onChanged: notifier.setPreset,
                ),
              ],
            ),
          ),
          Divider(height: 1, color: p.hairline, indent: 18, endIndent: 18),
          KonataListTile(
            title: 'GPU 硬件解码',
            subtitle: '自动启用 d3d11va / MediaCodec，遇异常源自动软解兜底',
            trailing: Switch(
              value: q.hardwareDecode,
              onChanged: notifier.setHardwareDecode,
            ),
          ),
          Divider(height: 1, color: p.hairline, indent: 18, endIndent: 18),
          KonataListTile(
            title: '去色带滤镜 (Deband)',
            subtitle: '消除 8-bit 动画暗部色彩断层，略微增加 GPU 负载',
            trailing: Switch(
              value: q.debandEnabled,
              onChanged: notifier.setDebandEnabled,
            ),
          ),
          Divider(height: 1, color: p.hairline, indent: 18, endIndent: 18),
          KonataListTile(
            title: '播完自动连播下一话',
            subtitle: '当前正片播放结束后无缝衔接下一话并继承音轨/字幕选择',
            trailing: Switch(
              value: prefs.autoNextEpisode,
              onChanged: notifier.setAutoNextEpisode,
            ),
          ),
          Divider(height: 1, color: p.hairline, indent: 18, endIndent: 18),
          KonataListTile(
            title: 'OP / ED 章节跳过提示',
            subtitle: '进入 OP/ED 区间时在右下角显示 4 秒一键跳过浮窗',
            trailing: Switch(
              value: prefs.promptChapterSkip,
              onChanged: notifier.setPromptChapterSkip,
            ),
          ),
          Divider(height: 1, color: p.hairline, indent: 18, endIndent: 18),
          KonataListTile(
            title: '检测到 OP / ED 自动跳过',
            subtitle: '无需手动确认，匹配到可信 OP/ED 章节区间时直接跳过',
            trailing: Switch(
              value: prefs.autoSkipChapter,
              onChanged: notifier.setAutoSkipChapter,
            ),
          ),
          if (KonataAdaptiveTokens.isAndroid) ...[
            Divider(height: 1, color: p.hairline, indent: 18, endIndent: 18),
            KonataListTile(
              key: const ValueKey('settings_auto_enter_pip'),
              title: '切入后台自动开启画中画',
              subtitle: '视频正在播放时切换至桌面或其他应用自动进入画中画小窗，暂停或纯音频模式下不触发',
              trailing: Switch(
                value: prefs.autoEnterPip,
                onChanged: notifier.setAutoEnterPip,
              ),
            ),
          ],
          Divider(height: 1, color: p.hairline, indent: 18, endIndent: 18),
          _buildCloudSubsetSection(p, prefs, notifier),
        ],
      ),
    );
  }

  Widget _buildCloudSubsetSection(
    KonataPalette p,
    PlaybackPreferencesState prefs,
    PlaybackPreferencesNotifier notifier,
  ) {
    final rawEndpoint = prefs.cloudSubsetEndpoint.trim();
    final parsedUri = rawEndpoint.isEmpty ? null : Uri.tryParse(rawEndpoint);
    CloudSubsetOrigin? validOrigin;
    if (parsedUri != null) {
      try {
        validOrigin = CloudSubsetOrigin.fromUri(parsedUri);
      } on FormatException {
        validOrigin = null;
      }
    }
    final isAuthorized =
        validOrigin != null &&
        parsedUri != null &&
        ref.read(cloudSubsetAuthorizationStoreProvider).isAuthorized(parsedUri);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        KonataListTile(
          key: const ValueKey('settings_cloud_subset_toggle'),
          title: '云端字幕字体子集化 (FontInAss · 可选)',
          subtitle: '默认关闭；开启并授权指定 Origin 后，可为缺字特效 ASS 按需生成子集字体缓存',
          trailing: Switch(
            value: prefs.cloudSubsetEnabled,
            onChanged: (enabled) {
              unawaited(notifier.setCloudSubsetEnabled(enabled));
              if (!enabled) {
                ref
                    .read(cloudSubsetCoordinatorProvider)
                    .cancelAllCloudSubsetTasks();
              }
            },
          ),
        ),
        if (prefs.cloudSubsetEnabled)
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                KonataSoftTextField(
                  key: const ValueKey('settings_cloud_subset_endpoint_field'),
                  controller: _cloudEndpointCtrl,
                  focusNode: _cloudEndpointFocus,
                  dense: true,
                  label: 'FontInAss 服务端点地址',
                  hintText: 'https://fontinass.example.com/subset',
                  keyboardType: TextInputType.url,
                  onChanged: (v) =>
                      unawaited(notifier.setCloudSubsetEndpoint(v)),
                ),
                const SizedBox(height: 8),
                if (validOrigin != null && parsedUri != null)
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      KonataSpecBadge(
                        key: const ValueKey(
                          'settings_cloud_subset_origin_badge',
                        ),
                        label: isAuthorized
                            ? '已授权 ${validOrigin.key}'
                            : '未授权 ${validOrigin.key}',
                        highlighted: isAuthorized,
                      ),
                      if (!isAuthorized)
                        KonataPillButton.secondary(
                          key: const ValueKey(
                            'settings_cloud_subset_authorize_button',
                          ),
                          label: '授权此源',
                          icon: Icons.verified_user_outlined,
                          compact: true,
                          onPressed: () {
                            final granted = ref
                                .read(cloudSubsetCoordinatorProvider)
                                .authorizeOrigin(parsedUri);
                            ref
                                    .read(
                                      cloudSubsetAuthRevisionProvider.notifier,
                                    )
                                    .state +=
                                1;
                            showKonataToast(
                              context,
                              '已授权云端子集化源：${granted.key}',
                            );
                          },
                        )
                      else
                        KonataPillButton.ghost(
                          key: const ValueKey(
                            'settings_cloud_subset_revoke_button',
                          ),
                          label: '撤销授权',
                          icon: Icons.gpp_bad_outlined,
                          compact: true,
                          onPressed: () {
                            ref
                                .read(cloudSubsetCoordinatorProvider)
                                .revokeOriginAndCancel(parsedUri);
                            ref
                                    .read(
                                      cloudSubsetAuthRevisionProvider.notifier,
                                    )
                                    .state +=
                                1;
                            showKonataToast(
                              context,
                              '已撤销授权并中止该源在途子集任务',
                            );
                          },
                        ),
                    ],
                  )
                else if (rawEndpoint.isNotEmpty)
                  Text(
                    '请输入合法的 http:// 或 https:// 服务地址',
                    style: TextStyle(color: p.danger, fontSize: 11.5),
                  ),
                const SizedBox(height: 6),
                Text(
                  '安全约束：授权绑定协议/主机/端口三元组，严禁跟随 3xx 跨源重定向，省略本地文件名且落盘前强制逐事件语义与 SFNT 字形检验。',
                  style: TextStyle(
                    color: p.textMuted,
                    fontSize: 11.5,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildAudioAndShaderCard(
    KonataPalette p,
    PlaybackPreferencesState prefs,
    PlaybackPreferencesNotifier notifier,
  ) {
    final q = prefs.qualityConfig;
    return KonataSurfaceCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '无损音频与着色器链路',
                  style: TextStyle(
                    color: p.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (KonataAdaptiveTokens.isWindows) ...[
                  const SizedBox(height: 12),
                  AdaptiveSettingTile(
                    padding: EdgeInsets.zero,
                    title: '默认 CD 音频引擎',
                    subtitle: '内置无损纯音频内核支持迷你浮窗底栏、全屏流光倒影页及 CUE/LRC 分轨歌词',
                    estimatedTrailingWidth: 220,
                    trailing: KonataSegmentedCapsule<PreferredPlaybackEngine>(
                      selected: prefs.defaultAudioEngine,
                      options: const [
                        KonataSegmentOption(
                          value: PreferredPlaybackEngine.builtinLibmpv,
                          label: '内置流光音频',
                        ),
                        KonataSegmentOption(
                          value: PreferredPlaybackEngine.externalPlayer,
                          label: '外部播放器',
                        ),
                      ],
                      onChanged: notifier.setDefaultAudioEngine,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Text(
                  'libsoxr 音频重采样精度',
                  style: TextStyle(color: p.textSecondary, fontSize: 12.5),
                ),
                const SizedBox(height: 6),
                KonataDropdown<int>(
                  dense: true,
                  value: q.audioResamplerPrecision,
                  options: const [
                    KonataDropdownOption(value: 16, label: '16-bit 标准实时'),
                    KonataDropdownOption(value: 24, label: '24-bit 清晰线性相位'),
                    KonataDropdownOption(value: 28, label: '28-bit 高保真推荐 (默认)'),
                    KonataDropdownOption(value: 33, label: '33-bit 极限解析度'),
                  ],
                  onChanged: notifier.setAudioResamplerPrecision,
                ),
              ],
            ),
          ),
          if (KonataAdaptiveTokens.isWindows) ...[
            Divider(height: 1, color: p.hairline, indent: 18, endIndent: 18),
            KonataListTile(
              title: 'WASAPI 音频独占模式',
              subtitle: 'Windows 直通声卡绕过混音；设备不支持时自动回退共享模式',
              trailing: Switch(
                value: q.wasapiExclusive,
                onChanged: notifier.setWasapiExclusive,
              ),
            ),
            Divider(height: 1, color: p.hairline, indent: 18, endIndent: 18),
            KonataListTile(
              key: const ValueKey('settings_hdmi_spdif_switch'),
              title: 'HDMI 源码直通 (audio-spdif)',
              subtitle: '透传 AC3 / DTS / TrueHD 比特流至功放；开启时与所有软件 DSP 严格互斥',
              trailing: Switch(
                value: prefs.hdmiSpdifPassthrough,
                onChanged: notifier.setHdmiSpdifPassthrough,
              ),
            ),
          ],
          if (KonataAdaptiveTokens.isAndroid) ...[
            Divider(height: 1, color: p.hairline, indent: 18, endIndent: 18),
            KonataListTile(
              key: const ValueKey('settings_android_bit_perfect_usb'),
              title: 'USB DAC 逐位直通 (Android 14+)',
              subtitle: '尝试协商原生 MIXER_BEHAVIOR_BIT_PERFECT，未连接兼容外设时自动回退高精 AAudio',
              trailing: Switch(
                value: prefs.androidBitPerfectUsb,
                onChanged: (enabled) => _toggleAndroidBitPerfectUsb(
                  enabled,
                  notifier: notifier,
                ),
              ),
            ),
          ],
          Divider(height: 1, color: p.hairline, indent: 18, endIndent: 18),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
            child: Container(
              key: const ValueKey('settings_audiophile_safety_notice'),
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: p.softFill,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: p.hairline, width: 1),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.shield_outlined,
                    size: 16,
                    color: p.textSecondary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      KonataAdaptiveTokens.isWindows &&
                              prefs.hdmiSpdifPassthrough
                          ? '当前已启用 HDMI audio-spdif 比特流透传，软件 DSP 与软限幅已严格互斥清空。'
                          : '${AudiophileSafetyPolicy.unverifiedFullScaleLockReason}；启播与跳转自动施加 ${AudiophileSafetyPolicy.defaultMicroFadeInMs} ms S 型微淡入与无缝预缓冲。',
                      style: TextStyle(
                        color: p.textSecondary,
                        fontSize: 11.5,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Divider(height: 1, color: p.hairline, indent: 18, endIndent: 18),
          KonataListTile(
            title: '倍速播放保持原音调',
            subtitle: '开启 Scaletempo2 音调修正，避免加速观看时人声变调',
            trailing: Switch(
              value: q.keepPitch,
              onChanged: notifier.setKeepPitch,
            ),
          ),
          Divider(height: 1, color: p.hairline, indent: 18, endIndent: 18),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AdaptiveResponsiveRow(
                  estimatedTrailingWidth: KonataAdaptiveTokens.isWindows
                      ? 176
                      : 84,
                  minLeadingWidth: 140,
                  leading: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'GLSL 自定义着色器',
                        style: TextStyle(
                          color: p.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '放入 userdata/shaders/ 下的 .glsl/.hook 文件（已识别 ${_shaderFiles.length} 个）',
                        style: TextStyle(
                          color: p.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                  trailing: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      KonataPillButton.ghost(
                        label: _scanningShaders ? '扫描中' : '刷新',
                        icon: Icons.refresh_rounded,
                        compact: true,
                        onPressed: _scanningShaders ? null : _scanShaders,
                      ),
                      if (KonataAdaptiveTokens.isWindows)
                        KonataPillButton.secondary(
                          label: '打开目录',
                          icon: Icons.folder_open_rounded,
                          compact: true,
                          onPressed: _openShadersFolder,
                        ),
                    ],
                  ),
                ),
                if (_shaderFiles.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final file in _shaderFiles)
                        _ShaderTogglePill(
                          label: path.basename(file.path),
                          selected: q.activeShaderPaths.contains(file.path),
                          onTap: () => notifier.toggleShaderPath(
                            file.path,
                            !q.activeShaderPaths.contains(file.path),
                          ),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ShaderTogglePill extends StatefulWidget {
  const _ShaderTogglePill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_ShaderTogglePill> createState() => _ShaderTogglePillState();
}

class _ShaderTogglePillState extends State<_ShaderTogglePill> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final selected = widget.selected;
    final bgColor = selected
        ? p.primaryButtonBg
        : (_hovered ? p.surfaceHover : p.softFill);
    final borderColor = selected
        ? p.primaryButtonBg
        : (_hovered ? p.hoverBorder : p.hairline);
    final fgColor = selected ? p.primaryButtonFg : p.textPrimary;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          constraints: KonataAdaptiveTokens.isAndroid
              ? const BoxConstraints(
                  minHeight: KonataAdaptiveTokens.touchTarget,
                  minWidth: KonataAdaptiveTokens.touchTarget,
                )
              : null,
          duration: KonataTheme.standardTransition,
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: borderColor, width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (selected) ...[
                Icon(Icons.check_rounded, size: 13.5, color: fgColor),
                const SizedBox(width: 5),
              ],
              Flexible(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: KonataTheme.textStyle(
                    color: fgColor,
                    fontSize: 12,
                    weight: selected
                        ? KonataTheme.weightActive
                        : KonataTheme.weightRegularLabel,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
