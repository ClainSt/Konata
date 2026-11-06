import 'settings_choice_card.dart';
import 'package:flutter/material.dart';
import '../core/app_language.dart';
import '../l10n/strings.dart';

class LanguageSettings extends StatefulWidget {
  const LanguageSettings({super.key, this.language});
  final AppLanguage? language;
  @override
  State<LanguageSettings> createState() => _LanguageSettingsState();
}

class _LanguageSettingsState extends State<LanguageSettings> {
  bool saving = false;
  AppLanguage get language => widget.language ?? AppLanguage.instance;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: language,
    builder: (context, _) => SettingsChoiceCard<AppLanguageChoice>(
      title: context.l10n.language,
      description: context.l10n.languageDescription,
      icon: Icons.language,
      value: language.choice,
      options: AppLanguageChoice.values,
      label: (choice) => switch (choice) {
        AppLanguageChoice.system => context.l10n.followSystem,
        AppLanguageChoice.zhHans => '简体中文',
        AppLanguageChoice.zhHant => '繁體中文',
        AppLanguageChoice.en => 'English',
      },
      selectorKey: const ValueKey('settings-language'),
      enabled: !saving,
      onChanged: (value) async {
        setState(() => saving = true);
        try {
          await language.setChoice(value);
        } catch (_) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(context.l10n.languageSaveFailed)),
            );
          }
        } finally {
          if (mounted) setState(() => saving = false);
        }
      },
    ),
  );
}
