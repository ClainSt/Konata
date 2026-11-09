import 'package:flutter/material.dart';
import '../core/optional_features.dart';
import '../l10n/strings.dart';

class ExtensionsPanel extends StatefulWidget {
  const ExtensionsPanel({super.key, this.settings});
  final OptionalFeatures? settings;
  @override
  State<ExtensionsPanel> createState() => _ExtensionsPanelState();
}

class _ExtensionsPanelState extends State<ExtensionsPanel> {
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
      if (snapshot.hasError) return Text(context.l10n.optionalFeatureFailed);
      if (snapshot.connectionState != ConnectionState.done) {
        return const LinearProgressIndicator();
      }
      return ListenableBuilder(
        listenable: settings,
        builder: (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(context.l10n.extensionsDescription),
            ),
            SwitchListTile(
              key: const ValueKey('extension-characters'),
              title: Text(context.l10n.bangumiPeopleData),
              value: settings.enabled(OptionalFeature.characters),
              onChanged: settings.saving
                  ? null
                  : (v) => _save(
                      () => settings.setEnabled(OptionalFeature.characters, v),
                    ),
            ),
            const Divider(),
            SwitchListTile(
              key: const ValueKey('extension-credits'),
              title: Text(context.l10n.tmdbPeopleData),
              value: settings.enabled(OptionalFeature.credits),
              onChanged: settings.saving
                  ? null
                  : (v) => _save(
                      () => settings.setEnabled(OptionalFeature.credits, v),
                    ),
            ),
          ],
        ),
      );
    },
  );
}
