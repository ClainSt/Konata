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

  String get metadataLanguage {
    final selected =
        locale ??
        resolve(WidgetsBinding.instance.platformDispatcher.locales, const []);
    if (selected.languageCode != 'zh') return 'en-US';
    return selected.scriptCode == 'Hant' ? 'zh-TW' : 'zh-CN';
  }

  // Bangumi exposes one untagged summary. Prefer it when its script matches
  // the requested language. Use TMDB's localized field when it is uncertain.
  static String? bangumiSynopsis(Object? value, String language) {
    if (value is! String || value.trim().isEmpty) return null;
    final han = RegExp(r'[\u3400-\u9fff]').hasMatch(value);
    final kana = RegExp(r'[\u3040-\u30ff\u31f0-\u31ff]').hasMatch(value);
    final hangul = RegExp(r'[\uac00-\ud7af]').hasMatch(value);
    if (language == 'en-US') {
      return !han && !kana && !hangul && RegExp(r'[A-Za-z]').hasMatch(value)
          ? value
          : null;
    }
    if (!han || kana || hangul) return null;
    if (language == 'zh-TW') {
      return RegExp(r'[這個們說國為與將發現時後關於裡讓從會學戰區對實過開門]').hasMatch(value) &&
              !RegExp(r'[这个们说国为与将发时后关于里让从会学战区对实过开门]').hasMatch(value)
          ? value
          : null;
    }
    return !RegExp(r'[這個們說國為與將發現時後關於裡讓從會學戰區對實過開門]').hasMatch(value)
        ? value
        : null;
  }

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
