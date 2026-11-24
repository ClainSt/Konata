import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';

/// 当 TMDB API 凭证尚未配置时展示在媒体源页顶部的轻提示引导条。
///
/// 点击「去配置」将通过 `AppNavigator` 直接跳转宿主设置中的网络代理与 API 页。
class TmdbScrapeGuardBanner extends StatelessWidget {
  /// 创建 TMDB 未配置提示条。
  const TmdbScrapeGuardBanner({
    super.key,
    required this.onConfigureTap,
  });

  /// 引导前往设置配置凭据的回调。
  final VoidCallback onConfigureTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final compact = MediaQuery.sizeOf(context).width < 640;

    return KonataSurfaceCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      backgroundColor: p.warning.withValues(alpha: 0.12),
      borderColor: p.warning.withValues(alpha: 0.36),
      child: Row(
        crossAxisAlignment:
            compact ? CrossAxisAlignment.start : CrossAxisAlignment.center,
        children: [
          Padding(
            padding: EdgeInsets.only(top: compact ? 2 : 0),
            child: Icon(
              Icons.key_off_rounded,
              size: 20,
              color: p.warning,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '尚未配置 TMDB API 凭证',
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: p.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '未填写 TMDB v3 Key 或 v4 Token 时仅能使用文件名与 Bangumi 信息，可能影响海报墙分集剧照与剧集绑定完整度。',
                  style: TextStyle(
                    fontSize: 12,
                    color: p.textSecondary,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          KonataPillButton.secondary(
            label: '去配置',
            icon: Icons.settings_outlined,
            compact: true,
            onPressed: onConfigureTap,
          ),
        ],
      ),
    );
  }
}

/// 当用户未配置 TMDB 凭证却直接点击扫库时弹出二次确认框；返回是否继续。
Future<bool> confirmScrapeWithoutTmdbIfNeeded(
  BuildContext context, {
  required bool isTmdbConfigured,
  required VoidCallback onOpenNetworkSettings,
}) async {
  if (isTmdbConfigured) return true;

  final result = await showKonataGlassDialog<bool>(
    context: context,
    builder: (dialogCtx) {
      final p = dialogCtx.palette;
      return KonataGlassDialog(
        title: '尚未配置 TMDB 凭证',
        width: 460,
        actions: [
          KonataPillButton.ghost(
            label: '去配置网络与 API',
            onPressed: () {
              Navigator.of(dialogCtx).pop(false);
              onOpenNetworkSettings();
            },
          ),
          KonataPillButton.secondary(
            label: '仅用当前方式扫描',
            onPressed: () => Navigator.of(dialogCtx).pop(true),
          ),
        ],
        child: Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            '检测到当前尚未配置 TMDB API Key / Read Access Token。仍然可以继续扫库，但部分条目的官方季集简介、横版背景原画与分集剧照将无法拉取。',
            style: TextStyle(
              fontSize: 13.5,
              color: p.textSecondary,
              height: 1.55,
            ),
          ),
        ),
      );
    },
  );
  return result ?? false;
}
