import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum ThemeAccent {
  sage('灰绿', Color(0xff35695c)),
  red('红色', Color(0xffdc3545)),
  pink('粉色', Color(0xfff3a6c8)),
  lightBlue('浅蓝色', Color(0xff8ad4f5));

  const ThemeAccent(this.label, this.color);
  final String label;
  final Color color;
  Color get foreground =>
      color.computeLuminance() > .45 ? const Color(0xff142b38) : Colors.white;
}

class AppTheme extends ChangeNotifier {
  AppTheme();
  static final instance = AppTheme();
  ThemeMode _mode = ThemeMode.system;
  ThemeMode get mode => _mode;
  ThemeAccent _accent = ThemeAccent.sage;
  ThemeAccent get accent => _accent;

  Future<void> load() async {
    final accentName = (await SharedPreferences.getInstance()).getString(
      'theme_accent',
    );
    _accent = ThemeAccent.values.firstWhere(
      (value) => value.name == accentName,
      orElse: () => ThemeAccent.sage,
    );
    final saved = (await SharedPreferences.getInstance()).getString(
      'theme_mode',
    );
    _mode = ThemeMode.values.firstWhere(
      (mode) => mode.name == saved,
      orElse: () => ThemeMode.system,
    );
    notifyListeners();
  }

  Future<void> setAccent(ThemeAccent value) async {
    final previous = _accent;
    _accent = value;
    notifyListeners();
    try {
      final saved = await (await SharedPreferences.getInstance()).setString(
        'theme_accent',
        value.name,
      );
      if (!saved) throw StateError('无法保存主题色');
    } catch (_) {
      _accent = previous;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> setMode(ThemeMode mode) async {
    final previous = _mode;
    _mode = mode;
    notifyListeners();
    try {
      final saved = await (await SharedPreferences.getInstance()).setString(
        'theme_mode',
        mode.name,
      );
      if (!saved) throw StateError('无法保存主题设置');
    } catch (_) {
      _mode = previous;
      notifyListeners();
      rethrow;
    }
  }
}
