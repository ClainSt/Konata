import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class WatchSettings extends ChangeNotifier {
  static final instance = WatchSettings();
  static const preferenceKey = 'watched_completion_percent';
  int _completionPercent = 90;
  int get completionPercent => _completionPercent;

  Future<void> load() async {
    final value = (await SharedPreferences.getInstance()).get(preferenceKey);
    _completionPercent = value is int && value >= 1 && value <= 100
        ? value
        : 90;
    notifyListeners();
  }

  Future<void> setCompletionPercent(int value) async {
    RangeError.checkValueInInterval(value, 1, 100);
    if (!await (await SharedPreferences.getInstance()).setInt(
      preferenceKey,
      value,
    )) {
      throw StateError('Could not save watch threshold');
    }
    _completionPercent = value;
    notifyListeners();
  }
}
