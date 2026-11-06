import 'settings_panel.dart';
import 'package:flutter/material.dart';
import '../core/watch_settings.dart';
import '../l10n/strings.dart';

class WatchedThresholdSettings extends StatefulWidget {
  const WatchedThresholdSettings({super.key, this.settings});
  final WatchSettings? settings;
  @override
  State<WatchedThresholdSettings> createState() =>
      _WatchedThresholdSettingsState();
}

class _WatchedThresholdSettingsState extends State<WatchedThresholdSettings> {
  WatchSettings get settings => widget.settings ?? WatchSettings.instance;
  int? draft;
  bool saving = false;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: settings,
    builder: (context, _) {
      final value = draft ?? settings.completionPercent;
      return SettingsPanel(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.autoWatched,
              style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(context.l10n.autoWatchedDescription),
            const SizedBox(height: 12),
            Text(
              '$value%',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            Slider(
              key: const ValueKey('watched-threshold'),
              value: value.toDouble(),
              min: 1,
              max: 100,
              divisions: 99,
              label: '$value%',
              onChanged: saving
                  ? null
                  : (v) => setState(() => draft = v.round()),
              onChangeEnd: saving
                  ? null
                  : (v) async {
                      setState(() => saving = true);
                      try {
                        await settings.setCompletionPercent(v.round());
                      } catch (_) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                context.l10n.watchSettingsSaveFailed,
                              ),
                            ),
                          );
                        }
                      } finally {
                        if (mounted) {
                          setState(() {
                            saving = false;
                            draft = null;
                          });
                        }
                      }
                    },
            ),
          ],
        ),
      );
    },
  );
}
