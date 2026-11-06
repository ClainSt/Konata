import '../l10n/strings.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'settings_navigation.dart';

/// Localized instructions kept separate from credential entry.
class TmdbApiGuide extends StatelessWidget {
  const TmdbApiGuide({super.key});

  static Future<void> show(BuildContext context) =>
      openSettingsScreen<void>(context, (_) => const TmdbApiGuide());

  Future<void> _open(BuildContext context) async {
    try {
      if (await launchUrl(
        Uri.parse('https://www.themoviedb.org/settings/api'),
      )) {
        return;
      }
    } catch (_) {
      // Keep the readable instructions available when no browser is installed.
    }
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.browserCopyFailed)));
    }
  }

  @override
  Widget build(BuildContext context) => SettingsFormSurface(
    dialog: AlertDialog(
      scrollable: true,
      title: Text(context.l10n.apiGuideTitle),
      content: SizedBox(
        width: 490,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            SelectableText(
              context.l10n.apiGuideBody,
              style: const TextStyle(fontSize: 15, height: 1.6),
            ),
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed: () => _open(context),
              icon: const Icon(Icons.open_in_new),
              label: Text(context.l10n.openApiPage),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.l10n.gotIt),
        ),
      ],
    ),
  );
}
