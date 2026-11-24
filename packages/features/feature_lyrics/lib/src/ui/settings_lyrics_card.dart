import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/lyrics_preferences.dart';

/// 全端统一在线歌词来源与注音设置卡片（由播放器设置分区与控制面板共用）。
class SettingsLyricsCard extends StatelessWidget {
  /// 使用分命名空间歌词偏好存取器构造设置卡片。
  const SettingsLyricsCard({
    super.key,
    required this.preferencesStore,
  });

  /// 歌词设置偏好存取器。
  final LyricsPreferencesStore preferencesStore;

  Future<void> _handleQqToggle(
    BuildContext context,
    LyricsPreferences prefs,
    bool enabled,
  ) async {
    if (!enabled) {
      preferencesStore.setQqEnabled(false);
      return;
    }
    if (prefs.qqDisclaimerAccepted) {
      preferencesStore.setQqEnabled(true);
      return;
    }
    final confirmed = await showKonataGlassDialog<bool>(
      context: context,
      builder: (dialogCtx) {
        final dp = dialogCtx.palette;
        return KonataGlassDialog(
          key: const ValueKey('qq_lyric_disclaimer_glass_dialog'),
          title: '启用非官方歌词接口提示',
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'QQ 音乐歌词查询使用第三方非官方公开接口，不涉及账号登录，也不会上传或收集个人凭据。'
                '该接口可能受对应平台服务条款调整、限流或结构变更影响，仅建议用于个人本地学习与歌词欣赏。'
                '是否确认知晓并启用？',
                style: KonataTheme.bodyLabelStyle(
                  dp,
                  fontSize: KonataTheme.fontSizeBodySm,
                  color: dp.textSecondary,
                ).copyWith(height: 1.55),
              ),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  KonataPillButton.secondary(
                    key: const ValueKey('qq_lyric_disclaimer_cancel'),
                    label: '暂不开启',
                    compact: true,
                    onPressed: () => Navigator.of(dialogCtx).pop(false),
                  ),
                  const SizedBox(width: 10),
                  KonataPillButton.primary(
                    key: const ValueKey('qq_lyric_disclaimer_confirm'),
                    label: '了解并开启',
                    icon: Icons.verified_user_outlined,
                    compact: true,
                    onPressed: () => Navigator.of(dialogCtx).pop(true),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
    if (confirmed == true) {
      preferencesStore.acceptQqDisclaimerAndEnable();
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return StreamBuilder<LyricsPreferences>(
      initialData: preferencesStore.read(),
      stream: preferencesStore.watch(),
      builder: (context, snapshot) {
        final prefs = snapshot.data ?? preferencesStore.read();
        return KonataSurfaceCard(
          key: const ValueKey('settings_lyrics_card'),
          padding: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('在线歌词来源与注音', style: KonataTheme.cardTitleStyle(p)),
                    const SizedBox(height: 4),
                    Text(
                      '本地同目录外挂 .lrc 与音轨内嵌歌词始终优先，未命中时按所选在线源并行竞速并本地缓存',
                      style: KonataTheme.captionStyle(p),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: p.hairline, indent: 18, endIndent: 18),
              KonataListTile(
                key: const ValueKey('settings_lyric_source_netease'),
                title: '网易云音乐歌词',
                subtitle: '覆盖绝大多数动画曲原文、中文译文与罗马音注音',
                trailing: KonataSwitch(
                  key: const ValueKey('settings_lyric_source_netease_switch'),
                  value: prefs.neteaseEnabled,
                  onChanged: preferencesStore.setNeteaseEnabled,
                ),
              ),
              Divider(height: 1, color: p.hairline, indent: 18, endIndent: 18),
              KonataListTile(
                key: const ValueKey('settings_lyric_source_amll'),
                title: 'AMLL 开源逐字歌词',
                subtitle: '按曲目编号直取社区 TTML 逐字与和声歌词，无需拉取全量索引',
                trailing: KonataSwitch(
                  key: const ValueKey('settings_lyric_source_amll_switch'),
                  value: prefs.amllEnabled,
                  onChanged: preferencesStore.setAmllEnabled,
                ),
              ),
              Divider(height: 1, color: p.hairline, indent: 18, endIndent: 18),
              KonataListTile(
                key: const ValueKey('settings_lyric_source_lrclib'),
                title: 'LRCLIB 开源歌词库',
                subtitle: '支持按时长精确匹配海外与动画曲时间轴，作为独立时间轴交叉校验源',
                trailing: KonataSwitch(
                  key: const ValueKey('settings_lyric_source_lrclib_switch'),
                  value: prefs.lrclibEnabled,
                  onChanged: preferencesStore.setLrclibEnabled,
                ),
              ),
              Divider(height: 1, color: p.hairline, indent: 18, endIndent: 18),
              KonataListTile(
                key: const ValueKey('settings_lyric_source_qq'),
                title: 'QQ 音乐歌词（非官方接口）',
                subtitle: '补充曲目与中文译文覆盖，首次启用需确认免责提示',
                trailing: KonataSwitch(
                  key: const ValueKey('settings_lyric_source_qq_switch'),
                  value: prefs.qqEnabled,
                  onChanged: (v) =>
                      unawaited(_handleQqToggle(context, prefs, v)),
                ),
              ),
              Divider(height: 1, color: p.hairline, indent: 18, endIndent: 18),
              KonataListTile(
                key: const ValueKey('settings_lyric_show_romaji'),
                title: '显示歌词罗马音注音',
                subtitle: '歌曲包含罗马音轨道时在原文下方独立显示注音，不与中文译文混排',
                trailing: KonataSwitch(
                  key: const ValueKey('settings_lyric_show_romaji_switch'),
                  value: prefs.showRomaji,
                  onChanged: preferencesStore.setShowRomaji,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
