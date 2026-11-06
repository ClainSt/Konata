import 'package:flutter/material.dart';

bool settingsUsePages(BuildContext context) => [
  TargetPlatform.android,
  TargetPlatform.iOS,
].contains(Theme.of(context).platform);

Future<T?> openSettingsScreen<T>(BuildContext context, WidgetBuilder builder) =>
    settingsUsePages(context)
    ? Navigator.of(context).push<T>(MaterialPageRoute(builder: builder))
    : showDialog<T>(context: context, builder: builder);

/// Uses the existing panel content as a full screen on phones.
class SettingsSurface extends Dialog {
  const SettingsSurface({
    super.key,
    super.child,
    super.insetPadding,
    super.shape,
    super.clipBehavior,
  });
  @override
  Widget build(BuildContext context) => settingsUsePages(context)
      ? Scaffold(
          body: SafeArea(child: SizedBox.expand(child: child)),
        )
      : super.build(context);
}

class SettingsFormSurface extends StatelessWidget {
  const SettingsFormSurface({super.key, required this.dialog});
  final AlertDialog dialog;
  @override
  Widget build(BuildContext context) {
    if (!settingsUsePages(context)) return dialog;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 12, 8),
              child: dialog.title,
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: dialog.content,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.end,
                children: dialog.actions ?? [],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
