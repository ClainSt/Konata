import 'package:ccplayer/core/mpv_input_keys.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native input uses MPV names for navigation and modifiers', () {
    expect(MpvInputKeys.encode(LogicalKeyboardKey.arrowLeft), 'LEFT');
    expect(MpvInputKeys.encode(LogicalKeyboardKey.arrowRight,
        shift: true, control: true), 'Ctrl+Shift+RIGHT');
    expect(MpvInputKeys.encode(LogicalKeyboardKey.space), 'SPACE');
    expect(MpvInputKeys.encode(LogicalKeyboardKey.escape), 'ESC');
    expect(MpvInputKeys.encode(LogicalKeyboardKey.enter), 'ENTER');
    expect(MpvInputKeys.encode(LogicalKeyboardKey.f5), 'F5');
  });

  test('letters preserve lowercase and shifted uppercase bindings', () {
    expect(MpvInputKeys.encode(LogicalKeyboardKey.keyA), 'a');
    expect(MpvInputKeys.encode(LogicalKeyboardKey.keyA, shift: true), 'A');
    expect(MpvInputKeys.encode(LogicalKeyboardKey.keyA, control: true), 'Ctrl+a');
    expect(MpvInputKeys.encode(LogicalKeyboardKey.keyQ, alt: true), 'Alt+q');
  });

  test('modifier-only and unrecognized keys do not enter MPV', () {
    expect(MpvInputKeys.encode(LogicalKeyboardKey.shiftLeft), isNull);
    expect(MpvInputKeys.encode(LogicalKeyboardKey.controlLeft), isNull);
  });
}
