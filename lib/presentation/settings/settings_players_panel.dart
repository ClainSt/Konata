import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../application/playback/audiophile_safety_coordinator.dart';
import '../../application/playback/playback_preferences_provider.dart';
import '../../application/playback/shader_discovery_provider.dart';
import '../../composition/platform_composition.dart';
import '../../domain/playback/ass_semantic_verifier.dart';
import '../../domain/playback/audiophile_safety_policy.dart';
import '../../infrastructure/players/mpv_quality_profile.dart';
import '../theme/konata_adaptive_tokens.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/adaptive_responsive_row.dart';
import '../widgets/design_system/konata_dropdown.dart';
import '../widgets/design_system/konata_glass_menu.dart';
import '../widgets/design_system/konata_pill_button.dart';
import '../widgets/design_system/konata_segmented_capsule.dart';
import '../widgets/design_system/konata_soft_text_field.dart';
import '../widgets/design_system/konata_surface_card.dart';
import '../widgets/design_system/konata_switch.dart';
import '../widgets/design_system/konata_system_file_picker.dart';
import '../widgets/design_system/konata_toast.dart';
import '../widgets/playback/konata_audiophile_unlock_dialog.dart';
import '../widgets/playback/konata_spec_badge.dart';

/// 播放器设置面板：
/// 内置 `libmpv` 引擎路由、动漫音画精细参数、可选云端字体子集化与异步 `shaders/` 着色器发现。
class SettingsPlayersPanel extends ConsumerStatefulWidget {
  /// 创建播放与音画还原设置面板。
  const SettingsPlayersPanel({super.key});

  @override
  ConsumerState<SettingsPlayersPanel> createState() =>
      _SettingsPlayersPanelState();
}

class _SettingsPlayersPanelState extends ConsumerState<SettingsPlayersPanel> {
  TextEditingController? _cloudEndpointCtrl;
  FocusNode? _cloudEndpointFocus;

  @override
  void dispose() {
    _cloudEndpointCtrl?.dispose();
    _cloudEndpointFocus?.dispose();
    super.dispose();
  }

  /// 仅当开启云端字幕字体子集化后懒分配输入控制器与焦点节点，减少空载常驻内存。
  ({TextEditingController controller, FocusNode focusNode})
  _ensureCloudEndpointInputs(String currentEndpoint) {
    final ctrl = _cloudEndpointCtrl ??= TextEditingController(
      text: currentEndpoint,
    );
    final focus = _cloudEndpointFocus ??= FocusNode();
    if (!focus.hasFocus && ctrl.text != currentEndpoint) {
      ctrl.text = currentEndpoint;
    }
    return (controller: ctrl, focusNode: focus);
  }

  Future<void> _toggleAndroidBitPerfectUsb(
    bool enabled, {
    required PlaybackPreferencesNotifier notifier,
  }) async {
    await notifier.setAndroidBitPerfectUsb(enabled);
    await ref
        .read(audiophileSafetyCoordinatorProvider)
        .reapplyAll(ref.read(playbackPreferencesProvider));
    final res = await ref
        .read(androidAudioRouteBridgeProvider)
        .negotiateBitPerfectUsb(enable: enabled);
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
          isError: true,
        );
      }
    } else {
      showKonataToast(context, '已切换回系统高精共享音频输出');
    }
  }

  Future<void> _openShadersFolder() async {
    try {
      final dirPath = await ref
          .read(shaderDiscoveryProvider.notifier)
          .ensureDirectoryPath();
      final ok = await launchUrl(
        Uri.file(dirPath),
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

  Future<void> _importShaders() async {
    try {
      // Android SAF 未注册 .glsl/.hook 的 MIME 类型，使用 FileType.any 配合后置扩展名校验避免文件灰显不可选。
      final picked = await ref
          .read(konataSystemFilePickerProvider)
          .pickFiles(
            dialogTitle: '选择 GLSL / HOOK 着色器脚本',
            type: FileType.any,
          );
      if (picked.isEmpty || !mounted) return;
      final sources = [
        for (final f in picked)
          ShaderImportSource(
            name: f.name,
            sourcePath: f.path,
            readBytes: f.readAsBytes,
          ),
      ];
      final result = await ref
          .read(shaderDiscoveryProvider.notifier)
          .importShaderFiles(sources);
      if (!mounted) return;
      if (result.imported.isNotEmpty) {
        final extra = result.skippedUnsupported > 0
            ? '（已忽略 ${result.skippedUnsupported} 个非 .glsl/.hook 文件）'
            : '';
        showKonataToast(context, '已导入 ${result.imported.length} 个着色器脚本$extra');
      } else if (result.skippedUnsupported > 0) {
        showKonataToast(
          context,
          '所选文件均不是 .glsl 或 .hook 着色器脚本',
          isError: true,
        );
      } else if (result.failedCount > 0) {
        showKonataToast(context, '导入着色器失败，请检查文件是否可读', isError: true);
      }
    } catch (e) {
      if (mounted) {
        showKonataToast(context, '导入着色器失败：$e', isError: true);
      }
    }
  }

  Future<void> _showShaderActionsMenu(
    BuildContext anchorContext, {
    required ShaderFileEntry file,
    required bool selected,
    required PlaybackPreferencesNotifier notifier,
  }) async {
    final action = await showKonataGlassMenu<String>(
      anchorContext: anchorContext,
      items: [
        KonataGlassMenuItem<String>(
          key: const ValueKey('shader_menu_toggle'),
          value: 'toggle',
          label: selected ? '停用此着色器' : '启用此着色器',
          icon: selected
              ? Icons.visibility_off_outlined
              : Icons.check_circle_outline_rounded,
        ),
        const KonataGlassMenuItem<String>(
          key: ValueKey('shader_menu_delete'),
          value: 'delete',
          label: '删除着色器文件',
          icon: Icons.delete_outline_rounded,
          isDanger: true,
        ),
      ],
    );
    if (!mounted || action == null) return;
    if (action == 'toggle') {
      await notifier.toggleShaderPath(file.path, !selected);
      return;
    }
    if (action == 'delete') {
      final ok = await ref
          .read(shaderDiscoveryProvider.notifier)
          .deleteShaderFile(file.path);
      if (!mounted) return;
      showKonataToast(
        context,
        ok ? '已删除着色器：${file.name}' : '删除着色器失败',
        isError: !ok,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final prefs = ref.watch(playbackPreferencesProvider);
    final shaders = ref.watch(shaderDiscoveryProvider);
    ref.watch(cloudSubsetAuthRevisionProvider);
    ref.watch(audiophileSafetyRevisionProvider);
    final notifier = ref.read(playbackPreferencesProvider.notifier);

    return LayoutBuilder(
      builder: (context, constraints) {
        final videoCard = _buildVideoQualityCard(p, prefs, notifier);
        final audioCard = _buildAudioAndShaderCard(
          p,
          prefs,
          notifier,
          shaders,
        );
        if (constraints.maxWidth >= 780) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: videoCard),
              const SizedBox(width: KonataAdaptiveTokens.settingsGap),
              Expanded(child: audioCard),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            videoCard,
            const SizedBox(height: KonataAdaptiveTokens.settingsGap),
            audioCard,
          ],
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
                Text('视频渲染与看番体验', style: KonataTheme.cardTitleStyle(p)),
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
                          value: PreferredPlaybackEngine.desktopRelay,
                          label: '外部播放器',
                        ),
                      ],
                      onChanged: notifier.setDefaultVideoEngine,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Text('画质与缩放预设', style: KonataTheme.captionStyle(p)),
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
                if (KonataAdaptiveTokens.isWindows) ...[
                  const SizedBox(height: 12),
                  Text('桌面高色深输出管线', style: KonataTheme.captionStyle(p)),
                  const SizedBox(height: 6),
                  KonataDropdown<VideoOutputPipelineMode>(
                    key: const ValueKey('settings_desktop_video_output_mode'),
                    dense: true,
                    value: q.outputPipelineMode,
                    options: [
                      for (final mode in VideoOutputPipelineMode.values)
                        KonataDropdownOption(value: mode, label: mode.label),
                    ],
                    onChanged: notifier.setOutputPipelineMode,
                  ),
                ],
              ],
            ),
          ),
          Divider(height: 1, color: p.hairline, indent: 18, endIndent: 18),
          KonataListTile(
            title: 'GPU 硬件解码',
            subtitle: ref.watch(platformHwdecSubtitleProvider),
            trailing: KonataSwitch(
              value: q.hardwareDecode,
              onChanged: notifier.setHardwareDecode,
            ),
          ),
          Divider(height: 1, color: p.hairline, indent: 18, endIndent: 18),
          KonataListTile(
            title: '去色带滤镜 (Deband)',
            subtitle: '消除 8-bit 动画暗部色彩断层，略微增加 GPU 负载',
            trailing: KonataSwitch(
              value: q.debandEnabled,
              onChanged: notifier.setDebandEnabled,
            ),
          ),
          Divider(height: 1, color: p.hairline, indent: 18, endIndent: 18),
          KonataListTile(
            title: '播完自动连播下一话',
            subtitle: '当前正片播放结束后无缝衔接下一话并继承音轨/字幕选择',
            trailing: KonataSwitch(
              value: prefs.autoNextEpisode,
              onChanged: notifier.setAutoNextEpisode,
            ),
          ),
          Divider(height: 1, color: p.hairline, indent: 18, endIndent: 18),
          KonataListTile(
            title: 'OP / ED 章节跳过提示',
            subtitle: '进入 OP/ED 区间时在右下角显示 4 秒一键跳过浮窗',
            trailing: KonataSwitch(
              value: prefs.promptChapterSkip,
              onChanged: notifier.setPromptChapterSkip,
            ),
          ),
          Divider(height: 1, color: p.hairline, indent: 18, endIndent: 18),
          KonataListTile(
            title: '检测到 OP / ED 自动跳过',
            subtitle: '无需手动确认，匹配到可信 OP/ED 章节区间时直接跳过',
            trailing: KonataSwitch(
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
              trailing: KonataSwitch(
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
    final cloudInputs = prefs.cloudSubsetEnabled
        ? _ensureCloudEndpointInputs(prefs.cloudSubsetEndpoint)
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        KonataListTile(
          key: const ValueKey('settings_cloud_subset_toggle'),
          title: '云端字幕字体子集化 (FontInAss · 可选)',
          subtitle: '开启并授权指定 Origin 后，可为缺字特效 ASS 按需生成子集字体缓存',
          trailing: KonataSwitch(
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
        if (prefs.cloudSubsetEnabled && cloudInputs != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                KonataSoftTextField(
                  key: const ValueKey('settings_cloud_subset_endpoint_field'),
                  controller: cloudInputs.controller,
                  focusNode: cloudInputs.focusNode,
                  dense: true,
                  label: 'FontInAss 服务端点地址',
                  hintText: PlaybackPreferencesState.defaultCloudSubsetEndpoint,
                  keyboardType: TextInputType.url,
                  onChanged: (v) =>
                      unawaited(notifier.setCloudSubsetEndpoint(v)),
                ),
                const SizedBox(height: KonataAdaptiveTokens.safeGap),
                if (validOrigin != null && parsedUri != null)
                  Wrap(
                    spacing: KonataAdaptiveTokens.safeGap,
                    runSpacing: KonataAdaptiveTokens.safeGap,
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
                      if (rawEndpoint !=
                          PlaybackPreferencesState.defaultCloudSubsetEndpoint)
                        KonataPillButton.ghost(
                          key: const ValueKey(
                            'settings_cloud_subset_reset_default_button',
                          ),
                          label: '恢复默认',
                          compact: true,
                          onPressed: () {
                            const def = PlaybackPreferencesState
                                .defaultCloudSubsetEndpoint;
                            cloudInputs.controller.text = def;
                            unawaited(notifier.setCloudSubsetEndpoint(def));
                          },
                        ),
                    ],
                  )
                else ...[
                  if (rawEndpoint.isNotEmpty)
                    Text(
                      '请输入合法的 http:// 或 https:// 服务地址',
                      style: KonataTheme.captionStyle(p, color: p.danger),
                    ),
                  const SizedBox(height: KonataAdaptiveTokens.safeGap),
                  KonataPillButton.ghost(
                    key: const ValueKey(
                      'settings_cloud_subset_reset_default_button',
                    ),
                    label: '恢复默认地址',
                    compact: true,
                    onPressed: () {
                      const def =
                          PlaybackPreferencesState.defaultCloudSubsetEndpoint;
                      cloudInputs.controller.text = def;
                      unawaited(notifier.setCloudSubsetEndpoint(def));
                    },
                  ),
                ],
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
    ShaderDiscoveryState shaders,
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
                Text('无损音频与着色器链路', style: KonataTheme.cardTitleStyle(p)),
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
                          value: PreferredPlaybackEngine.desktopRelay,
                          label: '外部播放器',
                        ),
                      ],
                      onChanged: notifier.setDefaultAudioEngine,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text('libsoxr 音频重采样精度', style: KonataTheme.captionStyle(p)),
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
              ],
            ),
          ),
          if (KonataAdaptiveTokens.isWindows) ...[
            Divider(height: 1, color: p.hairline, indent: 18, endIndent: 18),
            KonataListTile(
              title: ref.watch(platformExclusiveAudioTitleProvider),
              subtitle: '桌面直通声卡绕过混音；设备不支持时自动回退共享模式',
              trailing: KonataSwitch(
                value: q.exclusiveAudioOutput,
                onChanged: (v) async {
                  await notifier.setExclusiveAudioOutput(v);
                  await ref
                      .read(audiophileSafetyCoordinatorProvider)
                      .reapplyAll(ref.read(playbackPreferencesProvider));
                },
              ),
            ),
            Divider(height: 1, color: p.hairline, indent: 18, endIndent: 18),
            KonataListTile(
              key: const ValueKey('settings_hdmi_spdif_switch'),
              title: ref.watch(platformBitstreamTitleProvider),
              subtitle: '透传 AC3 / DTS / TrueHD 比特流至功放；开启时与所有软件 DSP 严格互斥',
              trailing: KonataSwitch(
                value: prefs.bitstreamPassthrough,
                onChanged: (v) async {
                  await notifier.setBitstreamPassthrough(v);
                  await ref
                      .read(audiophileSafetyCoordinatorProvider)
                      .reapplyAll(ref.read(playbackPreferencesProvider));
                },
              ),
            ),
          ],
          if (KonataAdaptiveTokens.isAndroid) ...[
            Divider(height: 1, color: p.hairline, indent: 18, endIndent: 18),
            KonataListTile(
              key: const ValueKey('settings_android_bit_perfect_usb'),
              title: 'USB DAC 逐位直通 (Android 14+)',
              subtitle: '尝试协商原生 MIXER_BEHAVIOR_BIT_PERFECT，未连接兼容外设时自动回退高精 AAudio',
              trailing: KonataSwitch(
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
            child: Builder(
              builder: (context) {
                final safetyState = ref
                    .read(audiophileSafetyCoordinatorProvider)
                    .deviceSafetyState;
                final hdmiOn =
                    KonataAdaptiveTokens.isWindows &&
                    prefs.bitstreamPassthrough;
                return Container(
                  key: const ValueKey('settings_audiophile_safety_notice'),
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: KonataAdaptiveTokens.horizontalInset,
                    vertical: KonataTheme.radiusControl,
                  ),
                  decoration: BoxDecoration(
                    color: p.softFill,
                    borderRadius: BorderRadius.circular(
                      KonataTheme.radiusControl,
                    ),
                    border: Border.all(
                      color: p.hairline,
                      width: KonataAdaptiveTokens.borderWidth,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.shield_outlined,
                            size: KonataAdaptiveTokens.settingsGap,
                            color: p.textSecondary,
                          ),
                          const SizedBox(width: KonataAdaptiveTokens.safeGap),
                          Expanded(
                            child: Text(
                              hdmiOn
                                  ? '当前已启用 HDMI audio-spdif 比特流透传，软件 DSP 与软限幅已严格互斥清空。'
                                  : safetyState.allowFullScaleBypass
                                  ? '当前外设已于本次会话二次确认解锁满幅逐位直通；重插外设将自动复位安全衰减。'
                                  : '${AudiophileSafetyPolicy.unverifiedFullScaleLockReason}；启播与跳转自动施加 ${AudiophileSafetyPolicy.defaultMicroFadeInMs} ms S 型微淡入与无缝预缓冲。',
                              style: KonataTheme.captionStyle(
                                p,
                                color: p.textSecondary,
                                height: 1.4,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (!hdmiOn && !safetyState.allowFullScaleBypass) ...[
                        const SizedBox(height: KonataAdaptiveTokens.safeGap),
                        KonataPillButton.ghost(
                          key: const ValueKey(
                            'settings_audiophile_unlock_button',
                          ),
                          label: '当次会话满幅确认',
                          icon: Icons.verified_user_outlined,
                          compact: true,
                          onPressed: () =>
                              showAudiophileFullScaleUnlockDialog(context, ref),
                        ),
                      ],
                    ],
                  ),
                );
              },
            ),
          ),
          Divider(height: 1, color: p.hairline, indent: 18, endIndent: 18),
          KonataListTile(
            title: '倍速播放保持原音调',
            subtitle: '开启 Scaletempo2 音调修正，避免加速观看时人声变调',
            trailing: KonataSwitch(
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
                      : 192,
                  minLeadingWidth: 140,
                  leading: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'GLSL 自定义着色器',
                        style: KonataTheme.bodyLabelStyle(p),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        KonataAdaptiveTokens.isAndroid
                            ? '点击导入 .glsl/.hook 超分脚本（如 Anime4K，已识别 ${shaders.files.length} 个；长按可删除）'
                            : '放入 userdata/shaders/ 下的 .glsl/.hook 文件（已识别 ${shaders.files.length} 个）',
                        style: KonataTheme.captionStyle(p),
                      ),
                    ],
                  ),
                  trailing: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      KonataPillButton.ghost(
                        label: shaders.isScanning ? '扫描中' : '刷新',
                        icon: Icons.refresh_rounded,
                        compact: true,
                        onPressed: shaders.isScanning
                            ? null
                            : () => unawaited(
                                ref
                                    .read(shaderDiscoveryProvider.notifier)
                                    .refresh(),
                              ),
                      ),
                      if (KonataAdaptiveTokens.isWindows)
                        KonataPillButton.secondary(
                          label: '打开目录',
                          icon: Icons.folder_open_rounded,
                          compact: true,
                          onPressed: _openShadersFolder,
                        )
                      else
                        KonataPillButton.secondary(
                          key: const ValueKey('settings_import_shader_button'),
                          label: '导入着色器',
                          icon: Icons.file_upload_outlined,
                          compact: true,
                          onPressed: _importShaders,
                        ),
                    ],
                  ),
                ),
                if (shaders.files.isNotEmpty) ...[
                  const SizedBox(height: KonataTheme.radiusControl),
                  Wrap(
                    spacing: KonataAdaptiveTokens.safeGap,
                    runSpacing: KonataAdaptiveTokens.safeGap,
                    children: [
                      for (final file in shaders.files)
                        Builder(
                          builder: (pillCtx) {
                            final isSelected = q.activeShaderPaths.contains(
                              file.path,
                            );
                            return _ShaderTogglePill(
                              label: file.name,
                              selected: isSelected,
                              onTap: () => notifier.toggleShaderPath(
                                file.path,
                                !isSelected,
                              ),
                              onShowMenu: () => unawaited(
                                _showShaderActionsMenu(
                                  pillCtx,
                                  file: file,
                                  selected: isSelected,
                                  notifier: notifier,
                                ),
                              ),
                            );
                          },
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
    required this.onShowMenu,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onShowMenu;

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
        onLongPress: widget.onShowMenu,
        onSecondaryTap: widget.onShowMenu,
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
            borderRadius: BorderRadius.circular(KonataTheme.radiusPill),
            border: Border.all(
              color: borderColor,
              width: KonataAdaptiveTokens.borderWidth,
            ),
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
                    fontSize: KonataTheme.captionStyle(p).fontSize,
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
