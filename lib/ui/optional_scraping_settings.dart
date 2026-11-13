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

  Widget _roleFilterTile(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final roles = settings.characterRoles;
    final all = roles.containsAll(OptionalFeatures.allCharacterRoles);
    final labels = <String, String>{
      'main': context.l10n.mainCharacter,
      'supporting': context.l10n.supportingCharacter,
      'guest': context.l10n.guestCharacter,
      'other': context.l10n.otherCharacter,
    };
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    final summary = all
        ? context.l10n.allCharacterRoles
        : roles.isEmpty
        ? context.l10n.featureOff
        : [
            for (final role in OptionalFeatures.allCharacterRoles)
              if (roles.contains(role)) labels[role]!,
          ].join(zh ? '、' : ', ');

    Widget option(
      String key,
      String label,
      bool checked,
      VoidCallback toggle, {
      bool mixed = false,
    }) => MenuItemButton(
      key: ValueKey(key),
      closeOnActivate: false,
      onPressed: settings.saving ? null : toggle,
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(208, 44)),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.hovered)
              ? colors.onSurface.withValues(alpha: .06)
              : Colors.transparent,
        ),
        textStyle: WidgetStatePropertyAll(
          Theme.of(context).textTheme.bodyMedium,
        ),
      ),
      trailingIcon: Icon(
        mixed ? Icons.remove : Icons.check,
        size: 17,
        color: checked || mixed ? colors.onSurface : Colors.transparent,
      ),
      child: Semantics(checked: checked, child: Text(label)),
    );

    return SettingsPanel(
      child: ListTile(
        key: const ValueKey('scraping-character-roles-tile'),
        title: Text(context.l10n.characterRoleFilter),
        trailing: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 220),
          child: MenuAnchor(
            alignmentOffset: const Offset(0, 8),
            style: MenuStyle(
              backgroundColor: WidgetStatePropertyAll(colors.surface),
              surfaceTintColor: const WidgetStatePropertyAll(
                Colors.transparent,
              ),
              elevation: const WidgetStatePropertyAll(2),
              shadowColor: WidgetStatePropertyAll(
                Colors.black.withValues(alpha: .08),
              ),
              padding: const WidgetStatePropertyAll(EdgeInsets.all(6)),
              side: WidgetStatePropertyAll(
                BorderSide(color: colors.outlineVariant.withValues(alpha: .6)),
              ),
              shape: WidgetStatePropertyAll(
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
            ),
            menuChildren: [
              option(
                'character-role-all',
                context.l10n.allCharacterRoles,
                all,
                () => _save(
                  () => settings.setCharacterRoles(
                    all ? const {} : {...OptionalFeatures.allCharacterRoles},
                  ),
                ),
                mixed: !all && roles.isNotEmpty,
              ),
              const Divider(height: 1),
              for (final role in OptionalFeatures.allCharacterRoles)
                option(
                  'character-role-$role',
                  labels[role]!,
                  roles.contains(role),
                  () => _save(
                    () => settings.setCharacterRoles(
                      roles.contains(role)
                          ? ({...roles}..remove(role))
                          : {...roles, role},
                    ),
                  ),
                ),
            ],
            builder: (context, controller, child) => TextButton(
              key: const ValueKey('scraping-character-roles-filter'),
              onPressed: settings.saving
                  ? null
                  : () => controller.isOpen
                        ? controller.close()
                        : controller.open(),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: colors.onSurface,
                      ),
                    ),
                  ),
                  const SizedBox(width: 2),
                  const Icon(Icons.expand_more, size: 18),
                ],
              ),
            ),
          ),
        ),
      ),
    );
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
                (settings.enabled(OptionalFeature.characters) ||
                    settings.enabled(OptionalFeature.credits))) ...[
              const SizedBox(height: 12),
              _roleFilterTile(context),
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
