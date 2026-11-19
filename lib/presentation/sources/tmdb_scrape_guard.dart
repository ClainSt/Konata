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
/// 当触发媒体库刮削、重刮削或手动匹配 TMDB 时调用。若尚未配置密钥，
/// 统一弹出毛玻璃提示窗引导用户前往「设置 -> 刮削与网络」完成配置并返回 `false`。
Future<bool> ensureTmdbConfiguredForScrape(
  BuildContext context,
  WidgetRef ref,
) async {
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
  final goSettings = await showKonataGlassDialog<bool>(
    context: context,
    builder: (dialogCtx) => KonataGlassDialog(
      width: 420,
      title: 'TMDB API 未配置',
      actions: [
        KonataPillButton.secondary(
          label: '关闭',
          compact: true,
          onPressed: () => Navigator.of(dialogCtx).pop(false),
        ),
        KonataPillButton.primary(
          label: '去配置',
          icon: Icons.tune_rounded,
          compact: true,
          onPressed: () => Navigator.of(dialogCtx).pop(true),
        ),
      ],
      child: Text(
        '尚未配置 TMDB API 密钥（API Key 或 Read Access Token），'
        '无法请求 TMDB 检索剧照、条目简介与分集信息。请前往「设置 -> 刮削与网络」完成配置。',
        style: TextStyle(color: p.textSecondary, fontSize: KonataTheme.fontSizeBody, height: 1.55),
      ),
    ),
  );
  if (goSettings == true && context.mounted) {
    Navigator.of(context).popUntil((route) => route.isFirst);
    ref.read(selectedSettingsCategoryProvider.notifier).state =
        SettingsCategory.network;
    ref.read(settingsDeepLinkPulseProvider.notifier).state++;
    ref.read(selectedNavSectionProvider.notifier).state =
        KonataNavSection.settings;
  }
  return false;
}
