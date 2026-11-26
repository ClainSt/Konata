import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';

/// 打开 TMDB API 凭据分步中文申请教程毛玻璃弹窗。
Future<void> showTmdbApiHelpDialog(
  BuildContext context, {
  required Future<bool> Function(Uri uri) onOpenExternalUrl,
}) {
  return showKonataGlassDialog<void>(
    context: context,
    builder: (_) => _TmdbApiHelpDialog(onOpenExternalUrl: onOpenExternalUrl),
  );
}

class _TmdbApiHelpDialog extends StatelessWidget {
  const _TmdbApiHelpDialog({required this.onOpenExternalUrl});

  static const String _summaryTemplate =
      'Personal non-commercial anime media library desktop application (Konata) '
      'for matching local video files, fetching localized titles, synopses, '
      'posters, and episode metadata for personal organization only.';

  static final Uri _tmdbSignupUri = Uri.parse(
    KonataNetworkConfig.tmdbSignupUrl,
  );
  static final Uri _tmdbApiSettingsUri = Uri.parse(
    KonataNetworkConfig.tmdbApiSettingsUrl,
  );

  final Future<bool> Function(Uri uri) onOpenExternalUrl;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    return KonataGlassDialog(
      width: 560,
      maxHeight: 540,
      title: '如何获取 TMDB API 密钥',
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
          padding: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '1. 注册并登录 TMDB 官网账号（免费）：',
                style: TextStyle(
                  color: p.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  KonataPillButton.secondary(
                    label: '打开 TMDB 注册页',
                    icon: Icons.open_in_new_rounded,
                    compact: true,
                    onPressed: () => onOpenExternalUrl(_tmdbSignupUri),
                  ),
                  KonataPillButton.secondary(
                    label: '打开 API 申请页面',
                    icon: Icons.key_rounded,
                    compact: true,
                    onPressed: () => onOpenExternalUrl(_tmdbApiSettingsUri),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                '2. 在「API」设置页选择 Developer（个人开发者）并填写英文申请理由，可直接复制下方模板：',
                style: TextStyle(
                  color: p.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              KonataSurfaceCard(
                padding: const EdgeInsets.all(14),
                radius: 12,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SelectableText(
                      _summaryTemplate,
                      style: TextStyle(
                        color: p.textSecondary,
                        fontSize: KonataTheme.fontSizeBodyXs,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerRight,
                      child: KonataPillButton.secondary(
                        label: '一键复制英文模板',
                        icon: Icons.copy_rounded,
                        compact: true,
                        onPressed: () async {
                          await Clipboard.setData(
                            const ClipboardData(text: _summaryTemplate),
                          );
                          if (context.mounted) {
                            showKonataToast(context, '已复制英文申请理由模板到剪贴板');
                          }
                        },
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Text(
                '3. 申请成功后，页面会显示「API Key (v3 auth)」与「API Read Access Token (v4 auth，以 eyJ 开头)」。\n'
                '   两种凭证任意复制一种直接粘贴到 Konata 密钥输入框即可，系统会自动识别认证方式。',
                style: TextStyle(
                  color: p.textSecondary,
                  fontSize: KonataTheme.fontSizeBodyXs,
                  height: 1.55,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
