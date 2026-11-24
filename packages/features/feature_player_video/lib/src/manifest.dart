import 'package:flutter/widgets.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';

import 'state/video_playback_controller.dart';
import 'ui/settings_external_tools_panel.dart';
import 'ui/settings_players_panel.dart';

/// 视频播放器业务包声明式模块清单。
///
/// 注册跨平台播放器设置分区、Windows 桌面专属外部工具设置分区，
/// 以及仅在全屏视频模式激活的侧栏扩展面板贡献。
final FeatureManifest featurePlayerVideoManifest = FeatureManifest(
  id: 'feature_player_video',
  displayName: '视频播放与悬浮小窗',
  settingsSections: <SettingsSectionContribution>[
    SettingsSectionContribution(
      id: 'playback_settings',
      title: '播放与解码',
      subtitle: '画质滤镜、硬件解码、着色器与音画输出策略',
      iconKey: 'player',
      order: 30,
      supportedPlatforms: allKonataPlatforms,
      viewBuilder: (slot) => const SettingsPlayersPanel(
        key: ValueKey('manifest_settings_players_panel'),
      ),
    ),
    SettingsSectionContribution(
      id: 'external_tools',
      title: '外部工具',
      subtitle: '配置桌面端外部播放器路径与远程进度同步服务',
      iconKey: 'tune',
      order: 40,
      supportedPlatforms: <KonataPlatform>{KonataPlatform.windows},
      viewBuilder: (slot) => const SettingsExternalToolsPanel(
        key: ValueKey('manifest_settings_external_tools_panel'),
      ),
    ),
  ],
  playerSidePanels: <PlayerSidePanelContribution>[
    PlayerSidePanelContribution(
      id: 'video_episode_specs',
      label: '信息与看完',
      iconKey: 'info',
      order: 90,
      supportedModes: const <PlayerMediaMode>{PlayerMediaMode.video},
      supportedPlatforms: allKonataPlatforms,
      viewBuilder: (slot) => _VideoSideSummaryContribution(slot: slot),
    ),
  ],
);

class _VideoSideSummaryContribution extends StatelessWidget {
  const _VideoSideSummaryContribution({required this.slot});

  final ViewSlotContext slot;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final ctrlObj = slot.arguments['controller'];
    final controller = ctrlObj is VideoPlaybackController ? ctrlObj : null;

    if (controller == null) {
      return Center(
        child: Text(
          '当前视频扩展信息面板就绪',
          style: TextStyle(color: p.textSecondary, fontSize: 13),
        ),
      );
    }

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final state = controller.state;
        final workTitle = state.currentWork?.title ?? '未知作品';
        final epId = state.currentEpisode.id;
        return ListView(
          key: const ValueKey('video_side_summary_contribution'),
          children: [
            KonataSurfaceCard(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    workTitle,
                    style: TextStyle(
                      color: p.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    state.currentVariant.fileName.isEmpty
                        ? '暂无物理文件'
                        : state.currentVariant.fileName,
                    style: TextStyle(color: p.textSecondary, fontSize: 12),
                  ),
                  const SizedBox(height: 12),
                  KonataPillButton.secondary(
                    compact: true,
                    icon: state.isCompletedCurrentEpisode
                        ? Icons.check_circle_rounded
                        : Icons.check_circle_outline_rounded,
                    label: state.isCompletedCurrentEpisode
                        ? '已标记看完（点击撤销）'
                        : '手动标记本集已看完',
                    onPressed: () {
                      controller.markEpisodeCompleted(
                        epId,
                        completed: !state.isCompletedCurrentEpisode,
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
