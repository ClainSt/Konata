import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';

/// 打开 Fanart.tv 个人客户端密钥说明毛玻璃弹窗。
Future<void> showFanartApiHelpDialog(
  BuildContext context, {
  required Future<bool> Function(Uri uri) onOpenExternalUrl,
}) {
  return showKonataGlassDialog<void>(
    context: context,
    builder: (dialogCtx) => _FanartApiHelpDialog(
      onOpenExternalUrl: onOpenExternalUrl,
    ),
  );
}

class _FanartApiHelpDialog extends StatelessWidget {
  const _FanartApiHelpDialog({required this.onOpenExternalUrl});

  static final Uri _fanartKeyUri = Uri.parse(
    'https://fanart.tv/get-an-api-key/',
  );

  final Future<bool> Function(Uri uri) onOpenExternalUrl;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<KonataPalette>()!;
    return KonataGlassDialog(
      title: '关于 Fanart.tv 高清徽标与原画密钥',
      width: 480,
      actions: [
        KonataPillButton.secondary(
          label: '前往 Fanart.tv 申请',
          icon: Icons.open_in_new_rounded,
          compact: true,
          onPressed: () => onOpenExternalUrl(_fanartKeyUri),
        ),
        KonataPillButton.primary(
          label: '关闭',
          compact: true,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Fanart.tv 提供番剧透明标题 Logo、宽屏背景原画等高阶艺术资源。',
            style: TextStyle(
              fontSize: 13.5,
              color: tokens.textPrimary,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '1. 个人客户端密钥（Client Key，选填）：绑定个人免费密钥可即时解锁最新发布的艺术图资源，免去 7 天公共延迟窗口。\n'
            '2. 自定义项目密钥（Project Key，可选高级覆盖）：填写后优先直连 Fanart 官方接口；留空则自动通过默认中继服务回退查询。',
            style: TextStyle(
              fontSize: 13,
              color: tokens.textSecondary,
              height: 1.55,
            ),
          ),
        ],
      ),
    );
  }
}
