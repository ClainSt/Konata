import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';

/// 打开 TMDB API 凭据申请说明毛玻璃弹窗。
Future<void> showTmdbApiHelpDialog(
  BuildContext context, {
  required Future<bool> Function(Uri uri) onOpenExternalUrl,
}) {
  return showKonataGlassDialog<void>(
    context: context,
    builder: (dialogCtx) => _TmdbApiHelpDialog(
      onOpenExternalUrl: onOpenExternalUrl,
    ),
  );
}

class _TmdbApiHelpDialog extends StatelessWidget {
  const _TmdbApiHelpDialog({required this.onOpenExternalUrl});

  static final Uri _tmdbSettingsUri = Uri.parse(
    'https://www.themoviedb.org/settings/api',
  );

  final Future<bool> Function(Uri uri) onOpenExternalUrl;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<KonataPalette>()!;
    return KonataGlassDialog(
      title: '如何获取 TMDB API 凭据',
      width: 480,
      actions: [
        KonataPillButton.secondary(
          label: '前往 TMDB API 页面',
          icon: Icons.open_in_new_rounded,
          compact: true,
          onPressed: () => onOpenExternalUrl(_tmdbSettingsUri),
        ),
        KonataPillButton.primary(
          label: '我知道了',
          compact: true,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Konata 支持自动识别以下两种 TMDB 凭据格式，并统一加密存入系统安全凭据库：',
            style: TextStyle(
              fontSize: 13.5,
              color: tokens.textPrimary,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 12),
          _HelpStep(
            number: '1',
            text: '登录 themoviedb.org 后打开「设置 → API」。',
            tokens: tokens,
          ),
          _HelpStep(
            number: '2',
            text: '申请或复制「API 读取访问令牌（v4 Token，以 eyJ 开头）」或「API 密钥（v3 Auth，32 位十六进制字符串）」。',
            tokens: tokens,
          ),
          _HelpStep(
            number: '3',
            text: '将密钥粘贴到本页输入框并保存，即可解锁海报、剧照与演职表高清刮削。',
            tokens: tokens,
          ),
        ],
      ),
    );
  }
}

class _HelpStep extends StatelessWidget {
  const _HelpStep({
    required this.number,
    required this.text,
    required this.tokens,
  });

  final String number;
  final String text;
  final KonataPalette tokens;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 20,
            height: 20,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: tokens.accent.withValues(alpha: 0.16),
              shape: BoxShape.circle,
            ),
            child: Text(
              number,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: tokens.accent,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13,
                color: tokens.textSecondary,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
