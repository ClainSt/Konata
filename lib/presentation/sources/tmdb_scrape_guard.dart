import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/library_providers.dart';
import '../../application/providers/scraping_providers.dart';
import '../settings/settings_page.dart';
import '../theme/konata_palette.dart';
import '../widgets/design_system/konata_glass_dialog.dart';
import '../widgets/design_system/konata_pill_button.dart';
import '../theme/konata_theme.dart';

/// 刮削前置校验：检查是否已配置 TMDB API 密钥。
///
/// 当触发媒体库刮削、重刮削或手动匹配 TMDB 时调用。若尚未配置密钥：
/// - `allowBangumiFallback == false`：引导用户前往「设置 -> 刮削与网络」完成配置并返回 `false`；
/// - `allowBangumiFallback == true`：额外提供「继续扫描」入口，允许直接依托 Bangumi / Fanart.tv 与本地封面建卡。
Future<bool> ensureTmdbConfiguredForScrape(
  BuildContext context,
  WidgetRef ref, {
  bool allowBangumiFallback = false,
}) async {
  var cfg = ref.read(tmdbNetworkConfigProvider).valueOrNull;
  if (cfg == null) {
    try {
      cfg = await ref.read(tmdbNetworkConfigProvider.future);
    } catch (_) {
      cfg = null;
    }
  }
  if (!context.mounted) {
    return false;
  }
  if (cfg != null && cfg.credential.trim().isNotEmpty) {
    return true;
  }
  final p = context.palette;
  final choice = await showKonataGlassDialog<String>(
    context: context,
    builder: (dialogCtx) => KonataGlassDialog(
      width: 440,
      title: 'TMDB API 未配置',
      actions: [
        KonataPillButton.secondary(
          label: '关闭',
          compact: true,
          onPressed: () => Navigator.of(dialogCtx).pop('close'),
        ),
        if (allowBangumiFallback)
          KonataPillButton.secondary(
            label: '仅用 Bangumi 扫描',
            compact: true,
            onPressed: () => Navigator.of(dialogCtx).pop('continue'),
          ),
        KonataPillButton.primary(
          label: '去配置',
          icon: Icons.tune_rounded,
          compact: true,
          onPressed: () => Navigator.of(dialogCtx).pop('settings'),
        ),
      ],
      child: Text(
        allowBangumiFallback
            ? '尚未配置 TMDB API 密钥，将无法拉取 TMDB 剧照与部分分集信息。'
                  '您可以前往「设置 -> 刮削与网络」配置密钥，或直接继续仅用 Bangumi / Fanart.tv 与本地封面建卡。'
            : '尚未配置 TMDB API 密钥（API Key 或 Read Access Token），'
                  '无法请求 TMDB 检索剧照、条目简介与分集信息。请前往「设置 -> 刮削与网络」完成配置。',
        style: TextStyle(
          color: p.textSecondary,
          fontSize: KonataTheme.fontSizeBody,
          height: 1.55,
        ),
      ),
    ),
  );
  if (choice == 'continue') {
    return true;
  }
  if (choice == 'settings' && context.mounted) {
    Navigator.of(context).popUntil((route) => route.isFirst);
    ref.read(selectedSettingsCategoryProvider.notifier).state =
        SettingsCategory.network;
    ref.read(settingsDeepLinkPulseProvider.notifier).state++;
    ref.read(selectedNavSectionProvider.notifier).state =
        KonataNavSection.settings;
  }
  return false;
}
