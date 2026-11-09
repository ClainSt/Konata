import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ArtworkSettings extends ChangeNotifier {
  static final instance = ArtworkSettings();
  static const backdropKey = 'detail_backdrop_enabled';
  bool _backdrop = true;
  bool get backdrop => _backdrop;

  Future<void> load() async {
    _backdrop =
        (await SharedPreferences.getInstance()).getBool(backdropKey) ?? true;
    notifyListeners();
  }

  Future<void> setBackdrop(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setBool(backdropKey, value)) {
      throw StateError('Cannot save artwork preference');
    }
    _backdrop = value;
    notifyListeners();
  }
}
