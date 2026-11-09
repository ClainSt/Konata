import 'package:flutter/material.dart';
import '../core/optional_features.dart';
import '../l10n/strings.dart';
import 'settings_panel.dart';
import 'settings_choice_card.dart';

/// Detailed preferences appear under scraping only while their feature is on.
class OptionalScrapingSettings extends StatefulWidget {
  const OptionalScrapingSettings({super.key, this.settings});
  final OptionalFeatures? settings;
  @override
  State<OptionalScrapingSettings> createState() =>
      _OptionalScrapingSettingsState();
}

class _OptionalScrapingSettingsState extends State<OptionalScrapingSettings> {
  late final settings = widget.settings ?? OptionalFeatures.instance;
  late final ready = settings.initialize();
  Future<void> _save(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.optionalFeatureFailed)),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<void>(
    future: ready,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done ||
          snapshot.hasError) {
        return const SizedBox.shrink();
      }
      return ListenableBuilder(
        listenable: settings,
        builder: (context, _) => Column(
          children: [
            if (settings.enabled(OptionalFeature.characters) ||
                settings.enabled(OptionalFeature.credits)) ...[
              const SizedBox(height: 12),
              SettingsPanel(
                child: SwitchListTile(
                  key: const ValueKey('scraping-people-visible'),
                  title: Text(context.l10n.peopleBar),
                  value: settings.peopleVisible,
                  onChanged: settings.saving
                      ? null
                      : (value) =>
                            _save(() => settings.setPeopleVisible(value)),
                ),
              ),
            ],
            if (settings.peopleVisible &&
                settings.enabled(OptionalFeature.characters)) ...[
              const SizedBox(height: 12),
              SettingsChoiceCard<int>(
                selectorKey: const ValueKey('scraping-bangumi-mode'),
                title: context.l10n.bangumiPeopleData,
                description: settings.enabled(OptionalFeature.credits)
                    ? context.l10n.peopleFallbackTmdb
                    : context.l10n.peopleFallbackHidden,
                icon: Icons.people_outline,
                value: settings.bangumiPresentation,
                enabled: !settings.saving,
                options: const [1, 2, 0],
                label: (value) => switch (value) {
                  1 => context.l10n.characters,
                  2 => context.l10n.voiceActors,
                  _ => context.l10n.featureOff,
                },
                onChanged: (value) =>
                    _save(() => settings.setBangumiPresentation(value)),
              ),
            ],
          ],
        ),
      );
    },
  );
}
