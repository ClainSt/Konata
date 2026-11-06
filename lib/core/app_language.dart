import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppLanguageChoice { system, zhHans, zhHant, en }

class AppLanguage extends ChangeNotifier {
  static final instance = AppLanguage();
  static const preferenceKey = 'ui_language';
  AppLanguageChoice _choice = AppLanguageChoice.system;
  AppLanguageChoice get choice => _choice;
  Locale? get locale => switch (_choice) {
    AppLanguageChoice.system => null,
    AppLanguageChoice.zhHans => const Locale.fromSubtags(
      languageCode: 'zh',
      scriptCode: 'Hans',
    ),
    AppLanguageChoice.zhHant => const Locale.fromSubtags(
      languageCode: 'zh',
      scriptCode: 'Hant',
    ),
    AppLanguageChoice.en => const Locale('en'),
  };

  Future<void> load() async {
    final saved = (await SharedPreferences.getInstance()).getString(
      preferenceKey,
    );
    _choice = AppLanguageChoice.values.firstWhere(
      (value) => value.name == saved,
      orElse: () => AppLanguageChoice.system,
    );
    notifyListeners();
  }

  Future<void> setChoice(AppLanguageChoice value) async {
    final saved = await (await SharedPreferences.getInstance()).setString(
      preferenceKey,
      value.name,
    );
    if (!saved) throw StateError('Could not save language');
    _choice = value;
    notifyListeners();
  }

  static Locale resolve(List<Locale>? preferred, Iterable<Locale> supported) {
    for (final locale in preferred ?? const <Locale>[]) {
      if (locale.languageCode == 'en') return const Locale('en');
      if (locale.languageCode == 'zh') {
        final traditional =
            locale.scriptCode == 'Hant' ||
            (locale.scriptCode != 'Hans' &&
                ['TW', 'HK', 'MO'].contains(locale.countryCode));
        return Locale.fromSubtags(
          languageCode: 'zh',
          scriptCode: traditional ? 'Hant' : 'Hans',
        );
      }
    }
    return const Locale('en');
  }
}
