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
    final tintBg = Color.alphaBlend(
      p.warning.withValues(alpha: p.isDark ? 0.14 : 0.09),
      p.surface,
    );
    final tintBorder = p.warning.withValues(alpha: p.isDark ? 0.36 : 0.32);

    return KonataSurfaceCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      backgroundColor: tintBg,
      borderColor: tintBorder,
      child: AdaptiveResponsiveRow(
        minLeadingWidth: 180,
        estimatedTrailingWidth: 108,
        leading: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: p.warningBadge.bg,
                borderRadius: KonataTheme.borderRadiusSm,
                border: Border.all(color: p.warningBadge.border),
              ),
              alignment: Alignment.center,
              child: Icon(
                Icons.key_off_rounded,
                size: 17,
                color: p.warningBadge.fg,
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
                    style: KonataTheme.cardTitleStyle(
                      p,
                      fontSize: KonataTheme.fontSizeBody,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '未填写 TMDB v3 Key 或 v4 Token 时将回退 Bangumi / Fanart 与本地封面建卡，可能影响官方季集简介与剧照完整度。',
                    style: KonataTheme.captionStyle(
                      p,
                      fontSize: KonataTheme.fontSizeCaption,
                      height: 1.45,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        trailing: KonataPillButton.secondary(
          label: '去配置',
          icon: Icons.tune_rounded,
          compact: true,
          onPressed: onConfigureTap,
        ),
      ),
    );
  }
}

/// 当用户未配置 TMDB 凭证却直接点击扫库时弹出二次确认框；返回是否继续。
Future<bool> confirmScrapeWithoutTmdbIfNeeded(
  BuildContext context, {
  required bool isTmdbConfigured,
  required VoidCallback onOpenNetworkSettings,
  bool allowBangumiFallback = true,
}) async {
  if (isTmdbConfigured) return true;

  final choice = await showKonataGlassDialog<String>(
    context: context,
    builder: (dialogCtx) {
      final p = dialogCtx.palette;
      return KonataGlassDialog(
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
      );
    },
  );
  if (choice == 'continue') {
    return true;
  }
  if (choice == 'settings') {
    onOpenNetworkSettings();
  }
  return false;
}
