import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/library_providers.dart';
import '../../application/providers/source_actions_provider.dart';
import '../../domain/models/external_player_config.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/konata_pill_button.dart';
import '../widgets/design_system/konata_soft_text_field.dart';
import '../widgets/design_system/konata_surface_card.dart';
import '../widgets/design_system/konata_toast.dart';

/// 设置页「外部调用」一级面板：独立管理外部视频播放器、外部音频播放器及外部看图工具。
class SettingsExternalToolsPanel extends ConsumerStatefulWidget {
  /// 创建外部调用设置面板。
  const SettingsExternalToolsPanel({super.key});

  @override
  ConsumerState<SettingsExternalToolsPanel> createState() =>
      _SettingsExternalToolsPanelState();
}

class _SettingsExternalToolsPanelState
    extends ConsumerState<SettingsExternalToolsPanel> {
  final TextEditingController _mpvController = TextEditingController();
  final TextEditingController _potController = TextEditingController();
  final TextEditingController _audioController = TextEditingController();
  final TextEditingController _imageController = TextEditingController();
  bool _initialized = false;

  @override
  void dispose() {
    _mpvController.dispose();
    _potController.dispose();
    _audioController.dispose();
    _imageController.dispose();
    super.dispose();
  }

  Future<void> _pickExecutable(
    TextEditingController target, {
    required String dialogTitle,
  }) async {
    final files = await FilePicker.pickFiles(
      dialogTitle: dialogTitle,
      type: FileType.custom,
      allowedExtensions: const ['exe'],
    );
    final path = files.firstOrNull?.path;
    if (path != null && path.isNotEmpty) {
      target.text = path;
    }
  }

  Future<void> _saveConfigs() async {
    final actions = ref.read(konataActionsProvider);
    await actions.saveExternalPlayer(
      ExternalPlayerConfig(
        id: 'player_mpv',
        name: 'MPV 播放器',
        kind: ExternalPlayerKind.mpv,
        executablePath: _mpvController.text.trim(),
        argumentsTemplate: '--force-window=yes {url}',
        isDefault: true,
      ),
    );
    await actions.saveExternalPlayer(
      ExternalPlayerConfig(
        id: 'player_potplayer',
        name: 'PotPlayer',
        kind: ExternalPlayerKind.potplayer,
        executablePath: _potController.text.trim(),
        argumentsTemplate: '{url}',
      ),
    );
    await actions.saveExternalPlayer(
      ExternalPlayerConfig(
        id: 'player_audio',
        name: '外部音频播放器',
        kind: ExternalPlayerKind.audioPlayer,
        executablePath: _audioController.text.trim(),
        argumentsTemplate: '{url}',
      ),
    );
    await actions.saveExternalPlayer(
      ExternalPlayerConfig(
        id: 'player_image_viewer',
        name: '外部图片查看器',
        kind: ExternalPlayerKind.imageViewer,
        executablePath: _imageController.text.trim(),
        argumentsTemplate: '{path}',
      ),
    );
    if (mounted) {
      showKonataToast(context, '外部调用配置已保存');
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final players =
        ref.watch(externalPlayersProvider).valueOrNull ?? const [];

    if (!_initialized && players.isNotEmpty) {
      _initialized = true;
      for (final player in players) {
        switch (player.kind) {
          case ExternalPlayerKind.mpv:
            _mpvController.text = player.executablePath;
          case ExternalPlayerKind.potplayer:
            _potController.text = player.executablePath;
          case ExternalPlayerKind.audioPlayer:
            _audioController.text = player.executablePath;
          case ExternalPlayerKind.imageViewer:
            _imageController.text = player.executablePath;
          case ExternalPlayerKind.custom:
            break;
        }
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('外部调用', style: KonataTheme.h2Style(p)),
        const SizedBox(height: 6),
        Text(
          '配置外部视频播放器（MPV / PotPlayer）与外部音画查看程序，用于热接力续播与右键指定打开',
          style: KonataTheme.captionStyle(p, fontSize: 13),
        ),
        const SizedBox(height: 18),
        KonataSurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '外部视频播放器与热接力',
                style: TextStyle(
                  color: p.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '可在右键菜单、多版本选播或内置播放器顶栏中一键热切换拉起并延续当前秒级进度',
                style: TextStyle(color: p.textSecondary, fontSize: 12.5),
              ),
              const SizedBox(height: 16),
              _ExternalPathFieldRow(
                controller: _mpvController,
                label: 'MPV 可执行文件路径（外部首选）',
                hintText: r'C:\Program Files\mpv\mpv.exe',
                icon: Icons.play_circle_outline_rounded,
                onBrowse: () => _pickExecutable(
                  _mpvController,
                  dialogTitle: '选择 MPV 播放器可执行文件',
                ),
              ),
              const SizedBox(height: 16),
              _ExternalPathFieldRow(
                controller: _potController,
                label: 'PotPlayer 可执行文件路径（备选）',
                hintText: r'C:\Program Files\DAUM\PotPlayer\PotPlayerMini64.exe',
                icon: Icons.ondemand_video_rounded,
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
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '外部音频与画册查看程序',
                style: TextStyle(
                  color: p.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '可指定 foobar2000 / Honeyview 等外部程序用于特定 CD 音轨或高清扫图浏览',
                style: TextStyle(color: p.textSecondary, fontSize: 12.5),
              ),
              const SizedBox(height: 16),
              _ExternalPathFieldRow(
                controller: _audioController,
                label: '外部音频播放器路径（CD / 无损可选）',
                hintText: r'C:\Program Files\foobar2000\foobar2000.exe',
                icon: Icons.library_music_outlined,
                onBrowse: () => _pickExecutable(
                  _audioController,
                  dialogTitle: '选择外部音频播放器可执行文件',
                ),
              ),
              const SizedBox(height: 16),
              _ExternalPathFieldRow(
                controller: _imageController,
                label: '外部图片查看器路径（Scan 扫图可选）',
                hintText: r'C:\Program Files\Honeyview\Honeyview.exe',
                icon: Icons.photo_library_outlined,
                onBrowse: () => _pickExecutable(
                  _imageController,
                  dialogTitle: '选择外部图片查看器可执行文件',
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Align(
          alignment: Alignment.centerLeft,
          child: KonataPillButton.primary(
            label: '保存外部调用配置',
            icon: Icons.save_outlined,
            onPressed: _saveConfigs,
          ),
        ),
      ],
    );
  }
}

class _ExternalPathFieldRow extends StatelessWidget {
  const _ExternalPathFieldRow({
    required this.controller,
    required this.label,
    required this.hintText,
    required this.icon,
    required this.onBrowse,
  });

  final TextEditingController controller;
  final String label;
  final String hintText;
  final IconData icon;
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
            prefixIcon: icon,
          ),
        ),
        const SizedBox(width: 10),
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: KonataPillButton.secondary(label: '浏览', onPressed: onBrowse),
        ),
      ],
    );
  }
}
