import 'package:flutter/widgets.dart';
import 'app_localizations.dart';

/// Fallback supports standalone widgets hosted without the app's delegates.
/// Production language selection is owned by MaterialApp.
extension LocalizedContext on BuildContext {
  AppLocalizations get l10n =>
      Localizations.of<AppLocalizations>(this, AppLocalizations) ??
      lookupAppLocalizations(
        const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
      );
}
