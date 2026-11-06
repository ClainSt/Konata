import '../l10n/strings.dart';
import 'settings_navigation.dart';
import 'package:flutter/material.dart';

class TmdbIdGuide extends StatelessWidget {
  const TmdbIdGuide({super.key});

  static Future<void> show(BuildContext context) =>
      openSettingsScreen<void>(context, (_) => const TmdbIdGuide());

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget section(String title, String body) => Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          SelectableText(
            body,
            style: TextStyle(
              fontSize: 14,
              height: 1.8,
              color: scheme.onSurface.withValues(alpha: .7),
            ),
          ),
        ],
      ),
    );
    return SettingsSurface(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 740),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      context.l10n.tmdbIdGuide,
                      style: TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: context.l10n.closeIdGuide,
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close, size: 22),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 8, 32, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    section(
                      context.l10n.idIntroTitle,
                      context.l10n.idIntroBody,
                    ),
                    section(
                      context.l10n.idFormatsTitle,
                      context.l10n.idFormats(
                        '{tmdb-100565}',
                        '{tmdbid=100565}',
                        '[tmdb-100565]',
                        '{tmdbmovie-ID}',
                      ),
                    ),
                    section(
                      context.l10n.idExampleTitle,
                      context.l10n.idExample(
                        'Anime/86 (2021) {tmdb-100565}/Season 1/S01E01.mkv',
                      ),
                    ),
                    section(context.l10n.idStepsTitle, context.l10n.idSteps),
                    section(context.l10n.idNotesTitle, context.l10n.idNotes),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              child: Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(context.l10n.gotIt),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
