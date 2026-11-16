import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;
import 'package:url_launcher/url_launcher.dart';

import '../../application/playback/playback_preferences_provider.dart';
import '../../infrastructure/players/mpv_quality_profile.dart';
import '../../infrastructure/storage/storage_root_provider.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/konata_dropdown.dart';
import '../widgets/design_system/konata_pill_button.dart';
import '../widgets/design_system/konata_segmented_capsule.dart';
import '../widgets/design_system/konata_surface_card.dart';
import '../widgets/design_system/konata_toast.dart';

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

  @override
  void initState() {
    super.initState();
    _loadShadersSync();
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
    final notifier = ref.read(playbackPreferencesProvider.notifier);
    final runtimeAsync = ref.watch(mpvRuntimeVersionsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '播放器',
          style: KonataTheme.h2Style(p),
        ),
        const SizedBox(height: 6),
        Text(
          '内置 libmpv D3D11 / MediaCodec 硬件管线与纯音频无损引擎配置，全自动音画还原与章节跳过控制',
          style: KonataTheme.captionStyle(p, fontSize: 13),
        ),
        const SizedBox(height: 18),
        _buildRuntimeAndEngineCard(p, prefs, notifier, runtimeAsync),
        const SizedBox(height: 16),
        LayoutBuilder(
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
              children: [
                videoCard,
                const SizedBox(height: 16),
                audioCard,
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _buildRuntimeAndEngineCard(
    KonataPalette p,
    PlaybackPreferencesState prefs,
    PlaybackPreferencesNotifier notifier,
    AsyncValue<MpvRuntimeVersions> runtimeAsync,
  ) {
    return KonataSurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '内置核心与默认路由',
                style: TextStyle(
                  color: p.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 10),
              runtimeAsync.when(
                data: (ver) => _RuntimeStatusPill(
                  label: ver.isAvailable
                      ? '${ver.mpvVersion} · FFmpeg ${ver.ffmpegVersion}'
                      : 'libmpv 运行时未就绪（将自动回退外部播放器）',
                  color: ver.isAvailable ? p.success : p.warning,
                ),
                loading: () =>
                    _RuntimeStatusPill(label: '正在探测内核...', color: p.textMuted),
                error: (e, st) =>
                    _RuntimeStatusPill(label: '内核探测失败', color: p.danger),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '默认视频播放引擎',
                      style: TextStyle(
                        color: p.textPrimary,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '点击正片或特典卡片时默认打开的播放器；右键卡片可随时临时指定其他播放器',
                      style: TextStyle(color: p.textSecondary, fontSize: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              KonataSegmentedCapsule<PreferredPlaybackEngine>(
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
            ],
          ),
          const SizedBox(height: 14),
          Divider(height: 1, color: p.hairline),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '默认 CD 音频引擎',
                      style: TextStyle(
                        color: p.textPrimary,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '内置无损纯音频内核支持迷你浮窗底栏、全屏流光倒影页及 CUE/LRC 分轨歌词',
                      style: TextStyle(color: p.textSecondary, fontSize: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              KonataSegmentedCapsule<PreferredPlaybackEngine>(
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
            ],
          ),
        ],
      ),
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
                      KonataDropdownOption(
                        value: preset,
                        label: preset.label,
                      ),
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
        ],
      ),
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
                    KonataDropdownOption(
                      value: 28,
                      label: '28-bit 高保真推荐 (默认)',
                    ),
                    KonataDropdownOption(value: 33, label: '33-bit 极限解析度'),
                  ],
                  onChanged: notifier.setAudioResamplerPrecision,
                ),
              ],
            ),
          ),
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
                Row(
                  children: [
                    Expanded(
                      child: Column(
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
                    ),
                    const SizedBox(width: 8),
                    KonataPillButton.ghost(
                      label: _scanningShaders ? '扫描中' : '刷新',
                      icon: Icons.refresh_rounded,
                      compact: true,
                      onPressed: _scanningShaders ? null : _scanShaders,
                    ),
                    const SizedBox(width: 4),
                    KonataPillButton.secondary(
                      label: '打开目录',
                      icon: Icons.folder_open_rounded,
                      compact: true,
                      onPressed: _openShadersFolder,
                    ),
                  ],
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

class _RuntimeStatusPill extends StatelessWidget {
  const _RuntimeStatusPill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
        ),
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
              Text(
                widget.label,
                style: KonataTheme.textStyle(
                  color: fgColor,
                  fontSize: 12,
                  weight: selected
                      ? KonataTheme.weightActive
                      : KonataTheme.weightRegularLabel,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
