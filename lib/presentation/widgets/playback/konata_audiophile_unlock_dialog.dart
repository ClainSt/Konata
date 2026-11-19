import 'package:flutter/material.dart';
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
  final safety = coordinator.deviceSafetyState;
  final prefs = ref.read(playbackPreferencesProvider);

  final confirmed = await showKonataGlassDialog<bool>(
    context: context,
    builder: (dialogContext) {
      final p = dialogContext.palette;
      final verified = safety.isBackendMeterVerified;
      return KonataGlassDialog(
        title: '当次会话满幅输出安全确认',
        width: 460,
        actions: [
          KonataPillButton.ghost(
            label: '保持安全限幅',
            onPressed: () => Navigator.of(dialogContext).pop(false),
          ),
          KonataPillButton.primary(
            key: const ValueKey('audiophile_unlock_confirm_button'),
            label: verified ? '确认解锁本次满幅' : '验证门锁状态',
            onPressed: () => Navigator.of(dialogContext).pop(true),
          ),
        ],
        child: Row(
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
                    ? '当前外设「${safety.deviceFingerprint}」已完成硬件电平仪实证。确认后将在本次会话内解除 -12 dBFS 末级安全限幅并进入满幅逐位直通；重新插拔外设后将自动复位安全衰减。'
                    : '${AudiophileSafetyPolicy.unverifiedFullScaleLockReason}。\n\n在完成物理硬件电平仪实证前，即使确认也无法绕过末级安全限幅，以保护您的听力与耳机设备。',
                style: KonataTheme.bodyLabelStyle(
                  p,
                  color: p.textSecondary,
                  height: 1.5,
                ),
              ),
            ),
          ],
        ),
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
