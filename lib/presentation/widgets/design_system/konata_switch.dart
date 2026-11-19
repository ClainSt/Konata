import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/konata_adaptive_tokens.dart';
import '../../theme/konata_palette.dart';
import '../../theme/konata_theme.dart';

/// 全站唯一标准毛玻璃胶囊开关组件（替代原生 Material `Switch`）。
///
/// 统一复用 `KonataPalette`、`KonataTheme` 几何/过渡令牌与 Android `48dp` 最小触控热区，
/// 支持键盘空格/回车触发与无障碍开关语义，静态驻留零空闲 Ticker。
class KonataSwitch extends StatefulWidget {
  /// 创建标准胶囊开关。
  const KonataSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.semanticLabel,
  });

  /// 当前开关选中状态。
  final bool value;

  /// 状态变更回调；为 `null` 时呈禁用态。
  final ValueChanged<bool>? onChanged;

  /// 可选无障碍语义标签。
  final String? semanticLabel;

  @override
  State<KonataSwitch> createState() => _KonataSwitchState();
}

class _KonataSwitchState extends State<KonataSwitch> {
  bool _hovered = false;
  bool _pressed = false;
  bool _focused = false;

  bool get _enabled => widget.onChanged != null;

  void _toggle() {
    final cb = widget.onChanged;
    if (cb == null) return;
    cb(!widget.value);
  }

  Color _resolveTrackColor(KonataPalette p) {
    if (!_enabled) {
      return p.softFill.withValues(alpha: 0.35);
    }
    if (widget.value) {
      if (_pressed) return p.primaryButtonBg.withValues(alpha: 0.78);
      if (_hovered) return p.primaryButtonBg.withValues(alpha: 0.88);
      return p.primaryButtonBg;
    }
    if (_pressed) return p.surfaceHover;
    if (_hovered) return p.softFill;
    return p.softFill.withValues(alpha: p.isDark ? 0.55 : 0.42);
  }

  Color _resolveBorderColor(KonataPalette p) {
    if (widget.value) {
      return _focused ? p.accent : Colors.transparent;
    }
    if (!_enabled) return p.hairline;
    if (_focused) return p.accent;
    if (_hovered || _pressed) return p.hoverBorder;
    return p.hairline;
  }

  Color _resolveThumbColor(KonataPalette p) {
    if (!_enabled) return p.textMuted.withValues(alpha: 0.5);
    if (widget.value) return p.primaryButtonFg;
    if (_hovered || _pressed) return p.textPrimary;
    return p.textSecondary;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final minHitHeight = KonataAdaptiveTokens.isAndroid
        ? KonataAdaptiveTokens.touchTarget
        : KonataTheme.switchTrackHeight;
    final minHitWidth = KonataAdaptiveTokens.isAndroid
        ? KonataAdaptiveTokens.touchTarget
        : KonataTheme.switchTrackWidth;

    return Semantics(
      label: widget.semanticLabel,
      toggled: widget.value,
      enabled: _enabled,
      button: true,
      child: FocusableActionDetector(
        enabled: _enabled,
        mouseCursor: _enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        onShowHoverHighlight: (hovered) {
          if (_hovered != hovered) {
            setState(() => _hovered = hovered);
          }
        },
        onShowFocusHighlight: (focused) {
          if (_focused != focused) {
            setState(() => _focused = focused);
          }
        },
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              _toggle();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _enabled ? _toggle : null,
          onTapDown: _enabled ? (_) => setState(() => _pressed = true) : null,
          onTapUp: _enabled ? (_) => setState(() => _pressed = false) : null,
          onTapCancel: _enabled
              ? () => setState(() => _pressed = false)
              : null,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: minHitWidth,
              minHeight: minHitHeight,
            ),
            child: Center(
              widthFactor: 1.0,
              heightFactor: 1.0,
              child: AnimatedContainer(
                duration: KonataTheme.standardTransition,
                curve: Curves.easeOutCubic,
                width: KonataTheme.switchTrackWidth,
                height: KonataTheme.switchTrackHeight,
                padding: const EdgeInsets.all(KonataTheme.switchThumbPadding),
                decoration: BoxDecoration(
                  color: _resolveTrackColor(p),
                  borderRadius: BorderRadius.circular(KonataTheme.radiusPill),
                  border: Border.all(
                    color: _resolveBorderColor(p),
                    width: KonataTheme.switchOutlineWidth,
                  ),
                ),
                child: AnimatedAlign(
                  duration: KonataTheme.standardTransition,
                  curve: Curves.easeOutCubic,
                  alignment: widget.value
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: AnimatedContainer(
                    duration: KonataTheme.standardTransition,
                    curve: Curves.easeOutCubic,
                    width: KonataTheme.switchThumbSize,
                    height: KonataTheme.switchThumbSize,
                    decoration: BoxDecoration(
                      color: _resolveThumbColor(p),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
