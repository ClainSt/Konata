import 'package:flutter/material.dart';
import '../theme/konata_adaptive_tokens.dart';
import '../theme/konata_palette.dart';
import '../widgets/design_system/konata_soft_text_field.dart';
import '../widgets/playback/konata_playback_capsule.dart';

/// 触屏与外接键盘共用的搜索、清除和主题入口。
class CapsuleShellActions extends StatefulWidget {
  const CapsuleShellActions({
    super.key,
    required this.query,
    required this.focusNode,
    required this.onChanged,
    required this.onToggleTheme,
  });
  final String query;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final VoidCallback onToggleTheme;
  @override
  State<CapsuleShellActions> createState() => _CapsuleShellActionsState();
}

class _CapsuleShellActionsState extends State<CapsuleShellActions> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.query,
  );
  @override
  void didUpdateWidget(covariant CapsuleShellActions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_controller.text != widget.query) _controller.text = widget.query;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: KonataSoftTextField(
          controller: _controller,
          focusNode: widget.focusNode,
          height: KonataAdaptiveTokens.touchTarget,
          hintText: '搜索媒体库',
          prefixIcon: Icons.search_rounded,
          onChanged: widget.onChanged,
          suffix: KonataCapsuleIconButton(
            icon: Icons.close_rounded,
            tooltip: '清除搜索',
            fixedSize: KonataAdaptiveTokens.touchTarget,
            color: context.palette.textPrimary,
            onTap: () {
              _controller.clear();
              widget.onChanged('');
            },
          ),
        ),
      ),
      KonataCapsuleIconButton(
        icon: Icons.brightness_6_rounded,
        tooltip: '切换深浅主题',
        fixedSize: KonataAdaptiveTokens.touchTarget,
        color: context.palette.textPrimary,
        onTap: widget.onToggleTheme,
      ),
    ],
  );
}
