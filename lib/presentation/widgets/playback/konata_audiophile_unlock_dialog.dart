import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../application/playback/audiophile_safety_coordinator.dart';
import '../../../application/playback/playback_preferences_provider.dart';
import '../../../domain/playback/audiophile_safety_policy.dart';
import '../../theme/konata_palette.dart';
import '../../theme/konata_theme.dart';
import '../design_system/konata_glass_dialog.dart';
import '../design_system/konata_pill_button.dart';
import '../design_system/konata_toast.dart';

/// 发烧音频满幅输出当次会话二次确认弹窗（防止外设切换或未实证后端导致爆音炸耳）。
///
/// 无论用户点击确认与否，底层均严格交由 `AudiophileSafetyCoordinator.confirmSessionFullScaleUnlock`
/// 核验物理硬件电平仪实证状态：未实证后端强制拒绝解锁并维持 `-12 dBFS` 末级安全上限。
Future<void> showAudiophileFullScaleUnlockDialog(
  BuildContext context,
  WidgetRef ref,
) async {
  final coordinator = ref.read(audiophileSafetyCoordinatorProvider);
  final prefs = ref.read(playbackPreferencesProvider);
  final routeMode = coordinator.resolveRouteMode(prefs);
  final canProbeBitPerfectRoute =
      routeMode == AudioOutputRouteMode.exclusiveAudioOutput ||
      routeMode == AudioOutputRouteMode.androidBitPerfectUsb;

  final confirmed = await showKonataGlassDialog<bool>(
    context: context,
    builder: (dialogContext) {
      String? probeNotice;
      var probing = false;
      return StatefulBuilder(
        builder: (innerContext, setDialogState) {
          final p = innerContext.palette;
          final safety = coordinator.deviceSafetyState;
          final verified = safety.isBackendMeterVerified;
          return KonataGlassDialog(
            title: '当次会话满幅输出安全确认',
            width: 480,
            actions: [
              KonataPillButton.ghost(
                label: '保持安全限幅',
                onPressed: () => Navigator.of(dialogContext).pop(false),
              ),
              if (!verified && canProbeBitPerfectRoute)
                KonataPillButton.ghost(
                  key: const ValueKey('audiophile_verify_route_button'),
                  label: probing ? '检测中…' : '检测直通链路',
                  onPressed: probing
                      ? null
                      : () async {
                          setDialogState(() {
                            probing = true;
                            probeNotice = null;
                          });
                          final res = await coordinator
                              .verifyActiveHardwareRoute(prefs);
                          if (!dialogContext.mounted) return;
                          setDialogState(() {
                            probing = false;
                            probeNotice = res.detail;
                          });
                        },
                ),
              KonataPillButton.primary(
                key: const ValueKey('audiophile_unlock_confirm_button'),
                label: verified ? '确认解锁本次满幅' : '验证门锁状态',
                onPressed: () => Navigator.of(dialogContext).pop(true),
              ),
            ],
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Icon(
                        Icons.shield_outlined,
                        size: 20,
                        color: verified ? p.accent : p.warning,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        verified
                            ? '当前外设「${safety.deviceFingerprint}」已完成直通链路核验。确认后将在本次会话内解除 -12 dBFS 末级安全限幅并清空软件 DSP，进入原生满幅逐位直通；重新插拔外设后将自动复位安全衰减。'
                            : '${AudiophileSafetyPolicy.unverifiedFullScaleLockReason}。\n\n${canProbeBitPerfectRoute ? '请点击下方「检测直通链路」完成当前硬件独占/逐位路由校验，通过后再确认解锁满幅原音直出。' : '如需启用满幅零 DSP 原音直出，请先开启「WASAPI 音频独占模式」或「USB DAC 逐位直通」，再完成硬件链路核验。'}',
                        style: KonataTheme.bodyLabelStyle(
                          p,
                          color: p.textSecondary,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                ),
                if (probeNotice != null && probeNotice!.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    probeNotice!,
                    style: KonataTheme.captionStyle(
                      p,
                      color: verified ? p.accent : p.warning,
                      height: 1.45,
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      );
    },
  );

  if (confirmed != true || !context.mounted) return;
  final unlocked = await coordinator.confirmSessionFullScaleUnlock(prefs);
  if (!context.mounted) return;
  if (unlocked) {
    showKonataToast(context, '已为当前外设解锁本次会话满幅逐位直通');
  } else {
    showKonataToast(
      context,
      AudiophileSafetyPolicy.unverifiedFullScaleLockReason,
      isError: true,
    );
  }
}
