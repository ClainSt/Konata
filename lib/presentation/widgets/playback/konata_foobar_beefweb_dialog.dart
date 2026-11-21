import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../application/playback/playback_preferences_provider.dart';
import '../../../domain/repositories/desktop_relay_service.dart';
import '../../theme/konata_palette.dart';
import '../../theme/konata_theme.dart';
import '../design_system/konata_glass_dialog.dart';
import '../design_system/konata_pill_button.dart';
import '../design_system/konata_toast.dart';

/// `foo_beefweb` 组件下载引导弹窗的用户决策结果。
enum FoobarGuideDialogAction {
  /// 关闭弹窗，不执行拉起。
  cancel,

  /// 已跳转浏览器前往官方页面下载组件。
  openedDownloadPage,

  /// 跳过提示并记录偏好，立即降级执行单向命令行播放。
  skipAndLaunchSingleWay,
}

/// 调用系统默认浏览器打开 `foobar2000` 官方 `foo_beefweb` 组件下载页面。
Future<void> openOfficialFoobarBeefwebDownload(BuildContext context) async {
  final uri = Uri.parse(FoobarBeefwebConfig.officialDownloadUrl);
  var launched = false;
  try {
    launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (error) {
    developer.log(
      '调用系统浏览器打开官方组件页异常已记录',
      name: 'konata.foobar_beefweb_dialog',
      error: error,
    );
  }
  if (!launched && context.mounted) {
    showKonataToast(
      context,
      '无法自动唤起浏览器，请手动访问：${FoobarBeefwebConfig.officialDownloadUrl}',
      isError: true,
    );
  }
}

/// 展示 `foobar2000` 缺少 `foo_beefweb` 组件时的统一毛玻璃引导弹窗。
Future<FoobarGuideDialogAction?> showFoobarBeefwebGuideDialog(
  BuildContext context,
) {
  return showKonataGlassDialog<FoobarGuideDialogAction>(
    context: context,
    builder: (ctx) {
      final p = ctx.palette;
      return KonataGlassDialog(
        key: const ValueKey('foobar_beefweb_guide_dialog'),
        width: 460,
        title: '启用 foobar2000 分轨与进度同步',
        onClose: () => Navigator.of(ctx).pop(FoobarGuideDialogAction.cancel),
        actions: [
          KonataPillButton.ghost(
            key: const ValueKey('foobar_guide_skip_once_or_forever'),
            label: '仅单文件播放（不再提示）',
            compact: true,
            onPressed: () => Navigator.of(
              ctx,
            ).pop(FoobarGuideDialogAction.skipAndLaunchSingleWay),
          ),
          KonataPillButton.primary(
            key: const ValueKey('foobar_guide_open_download'),
            label: '前往官方组件页下载',
            icon: Icons.open_in_browser_rounded,
            compact: true,
            onPressed: () async {
              await openOfficialFoobarBeefwebDownload(ctx);
              if (ctx.mounted) {
                Navigator.of(
                  ctx,
                ).pop(FoobarGuideDialogAction.openedDownloadPage);
              }
            },
          ),
        ],
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '检测到当前配置的 foobar2000 尚未安装 foo_beefweb 远程控制组件。原版 foobar2000 不提供外部进度与播放列表控制接口。',
              style: KonataTheme.bodyLabelStyle(
                p,
                fontSize: KonataTheme.fontSizeBodySm,
                color: p.textPrimary,
              ).copyWith(height: 1.5),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: p.softFill,
                borderRadius: KonataTheme.borderRadiusControl,
                border: Border.all(color: p.hairline),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '安装组件后即可解锁：',
                    style: TextStyle(
                      color: p.textPrimary,
                      fontSize: KonataTheme.fontSizeCaption,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '1. WebDAV / 本地整轨 CUE 自动拆分为独立多曲目列表；\n'
                    '2. 自动继承上次听到的子轨与秒数，并在切歌/停止时回写进度；\n'
                    '3. 隔离维护专属「Konata」播放列表，绝不覆盖你的默认歌单。',
                    style: TextStyle(
                      color: p.textSecondary,
                      fontSize: KonataTheme.fontSizeCaption,
                      height: 1.55,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '安装方法：在官方组件页下载 .fb2k-component 文件后直接双击打开，点击 Apply 重启 foobar2000 即可（默认端口 8880）。',
              style: TextStyle(
                color: p.textMuted,
                fontSize: KonataTheme.fontSizeCaptionXs,
                height: 1.45,
              ),
            ),
          ],
        ),
      );
    },
  );
}

/// 外部音频播放与热接力表现层统一协调辅助（统一承接 `foo_beefweb` 引导弹窗、降级重试与 `Toast` 提示）。
abstract final class ExternalAudioRelayUiHelper {
  /// 执行外部音频分发动作，若返回需引导安装 `foo_beefweb` 则弹出统一毛玻璃引导框。
  static Future<LaunchPlaybackResult> dispatchWithGuide({
    required BuildContext context,
    required WidgetRef ref,
    required Future<LaunchPlaybackResult> Function({
      required bool forceAllowWithoutBeefweb,
    })
    action,
  }) async {
    final firstRes = await action(forceAllowWithoutBeefweb: false);
    if (firstRes.requiresBeefwebPrompt) {
      if (!context.mounted) return firstRes;
      final choice = await showFoobarBeefwebGuideDialog(context);
      if (choice == FoobarGuideDialogAction.skipAndLaunchSingleWay) {
        await ref
            .read(playbackPreferencesProvider.notifier)
            .setSkipFoobarBeefwebPrompt(true);
        final retryRes = await action(forceAllowWithoutBeefweb: true);
        if (context.mounted && retryRes.message.isNotEmpty) {
          showKonataToast(
            context,
            retryRes.message,
            isError: !retryRes.launched,
          );
        }
        return retryRes;
      }
      return firstRes;
    }

    if (context.mounted && firstRes.message.isNotEmpty) {
      showKonataToast(context, firstRes.message, isError: !firstRes.launched);
    }
    return firstRes;
  }
}
