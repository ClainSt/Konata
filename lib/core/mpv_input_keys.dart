import 'package:flutter/services.dart';

/// Map Flutter physical keyboard events to MPV input.conf key names.
/// This deliberately ignores IME, dead keys, mouse events and unsupported keys.
abstract final class MpvInputKeys {
  static String? encode(
    LogicalKeyboardKey key, {
    bool shift = false,
    bool control = false,
    bool alt = false,
    bool meta = false,
  }) {
    final known = <LogicalKeyboardKey, String>{
      LogicalKeyboardKey.arrowLeft: 'LEFT',
      LogicalKeyboardKey.arrowRight: 'RIGHT',
      LogicalKeyboardKey.arrowUp: 'UP',
      LogicalKeyboardKey.arrowDown: 'DOWN',
      LogicalKeyboardKey.space: 'SPACE',
      LogicalKeyboardKey.enter: 'ENTER',
      LogicalKeyboardKey.numpadEnter: 'KP_ENTER',
      LogicalKeyboardKey.escape: 'ESC',
      LogicalKeyboardKey.backspace: 'BS',
      LogicalKeyboardKey.delete: 'DEL',
      LogicalKeyboardKey.tab: 'TAB',
      LogicalKeyboardKey.home: 'HOME',
      LogicalKeyboardKey.end: 'END',
      LogicalKeyboardKey.pageUp: 'PGUP',
      LogicalKeyboardKey.pageDown: 'PGDWN',
      LogicalKeyboardKey.insert: 'INS',
      LogicalKeyboardKey.f1: 'F1',
      LogicalKeyboardKey.f2: 'F2',
      LogicalKeyboardKey.f3: 'F3',
      LogicalKeyboardKey.f4: 'F4',
      LogicalKeyboardKey.f5: 'F5',
      LogicalKeyboardKey.f6: 'F6',
      LogicalKeyboardKey.f7: 'F7',
      LogicalKeyboardKey.f8: 'F8',
      LogicalKeyboardKey.f9: 'F9',
      LogicalKeyboardKey.f10: 'F10',
      LogicalKeyboardKey.f11: 'F11',
      LogicalKeyboardKey.f12: 'F12',
    };
    final base = known[key];
    if (base != null) {
      return _join(base, shift: shift, control: control, alt: alt, meta: meta);
    }
    final value = key.keyLabel;
    if (value.length != 1 || value.codeUnitAt(0) < 33 ||
        value.codeUnitAt(0) > 126) {
      return null;
    }
    // MPV uses capital letters for Shift+letter, other shortcuts use modifiers.
    final isLetter = RegExp(r'^[A-Za-z]$').hasMatch(value);
    final symbol = isLetter
        ? (shift ? value.toUpperCase() : value.toLowerCase())
        : value;
    return _join(symbol,
        shift: !isLetter && shift, control: control, alt: alt, meta: meta);
  }

  static String _join(
    String name, {
    required bool shift,
    required bool control,
    required bool alt,
    required bool meta,
  }) {
    final modifiers = <String>[
      if (control) 'Ctrl',
      if (alt) 'Alt',
      if (meta) 'Meta',
      if (shift) 'Shift',
      name,
    ];
    return modifiers.join('+');
  }
}
