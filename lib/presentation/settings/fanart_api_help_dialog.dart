import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../domain/models/network_config.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/konata_draggable_scrollbar.dart';
import '../widgets/design_system/konata_glass_dialog.dart';
import '../widgets/design_system/konata_pill_button.dart';
import '../widgets/design_system/konata_surface_card.dart';

/// Fanart.tv 个人密钥（Client Key）选填获取指引毛玻璃弹窗。
class FanartApiHelpDialog extends StatelessWidget {
  /// 创建 Fanart.tv 个人密钥说明弹窗。
  const FanartApiHelpDialog({super.key});

  Future<void> _openUrl(String url) async {
    final uri = Uri.parse(url);
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    return KonataGlassDialog(
      width: 520,
      maxHeight: 460,
      title: '如何获取 Fanart.tv 个人密钥',
      actions: [
        KonataPillButton.primary(
          label: '我知道了',
          compact: true,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
      child: KonataDraggableScrollbar(
        builder: (_, ctrl) => SingleChildScrollView(
          controller: ctrl,
          padding: const EdgeInsets.only(right: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              KonataSurfaceCard(
                padding: const EdgeInsets.all(12),
                radius: KonataTheme.radiusCard,
                child: Text(
                  '此项为完全选填：留空时 Konata 默认通过内置无状态中继自动补充透明标题徽标；'
                  '填入个人 Key（Client Key）后可跳过约 7 天的公共新图延迟，更快获取当季新番透明 Logo，并享有更高的独立请求配额。',
                  style: TextStyle(
                    color: p.textSecondary,
                    fontSize: KonataTheme.fontSizeBodyXs,
                    height: 1.55,
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                '1. 登录 Fanart.tv 官网并免费创建 Personal API Key（Client Key）：',
                style: TextStyle(
                  color: p.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              KonataPillButton.secondary(
                label: '打开 Fanart.tv API 申请页',
                icon: Icons.open_in_new_rounded,
                compact: true,
                onPressed: () => _openUrl(TmdbNetworkConfig.fanartGetApiKeyUrl),
              ),
              const SizedBox(height: 14),
              Text(
                '2. 将页面生成的 Personal API Key 粘贴到「Fanart.tv 个人密钥」输入框即可自动生效。\n'
                '3. 若遇到内置中继限流或希望自行直连 Fanart.tv，也可在「高级设置与连接测试」中填入自定义 Project API Key（api-key）覆盖内置通道。',
                style: TextStyle(
                  color: p.textSecondary,
                  fontSize: KonataTheme.fontSizeBodyXs,
                  height: 1.6,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
