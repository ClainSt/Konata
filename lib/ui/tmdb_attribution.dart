import 'settings_panel.dart';
import 'package:flutter/material.dart';
import '../l10n/strings.dart';
import 'package:url_launcher/url_launcher.dart';

/// TMDB attribution, independent of scraping credentials and configuration.
class TmdbAttribution extends StatelessWidget {
  const TmdbAttribution({super.key});

  static final website = Uri.parse('https://www.themoviedb.org');

  @override
  Widget build(BuildContext context) {
    return SettingsPanel(
      child: ListTile(
        leading: Image.asset(
          'assets/brand/tmdb-logo.png',
          width: 56,
          height: 28,
          fit: BoxFit.contain,
          semanticLabel: 'TMDB — The Movie Database',
        ),
        title: const Text(
          'TMDB',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: const Text(
          'This product uses the TMDB API but is not endorsed or certified by TMDB.',
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _openWebsite(context),
      ),
    );
  }

  Future<void> _openWebsite(BuildContext context) async {
    try {
      final opened = await launchUrl(
        website,
        mode: LaunchMode.externalApplication,
      );
      if (!opened) throw StateError('Browser unavailable');
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.l10n.tmdbOpenFailed)));
      }
    }
  }
}
