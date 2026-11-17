import 'dart:typed_data';

import 'package:smb_connect/src/utils/extensions.dart';

/// 基于公开标准 NIST SP 800-108 计数器模式的密钥派生生成器（支持前置/中置/后置计数 counter 布局）。
/// <ul>
/// </ul>
/// <ul>
///  <li>KI</li>
///  </ul>
/// <ul>
/// </ul>
class KDFCounterParameters {
  final Uint8List _ki;
  final Uint8List _fixedInputDataCounterPrefix;
  final Uint8List _fixedInputDataCounterSuffix;
  final int _r;

  /// 仅提供计数后固定后缀字节的 SP800-108 参数构造器。
  KDFCounterParameters.suffix(
      Uint8List ki, Uint8List fixedInputDataCounterSuffix, int r)
      : this(ki, null, fixedInputDataCounterSuffix, r);

  /// 同时提供计数前后缀固定输入字节的 SP800-108 参数构造器。
  KDFCounterParameters(this._ki, Uint8List? fixedInputDataCounterPrefix,
      Uint8List? fixedInputDataCounterSuffix, this._r)
      : _fixedInputDataCounterPrefix =
            fixedInputDataCounterPrefix ?? Uint8List(0),
        _fixedInputDataCounterSuffix =
            fixedInputDataCounterSuffix ?? Uint8List(0) {
    // }

    // }

    // }

    if (_r != 8 && _r != 16 && _r != 24 && _r != 32) {
      throw "Length of counter should be 8, 16, 24 or 32";
    }
  }

  Uint8List getKI() {
    return _ki;
  }

  Uint8List getFixedInputData() {
    // 保留兼容别名以维系旧版接口兼容。
    return _fixedInputDataCounterSuffix
        .toUint8List(); //Arrays.clone(fixedInputDataCounterSuffix);
  }

  Uint8List getFixedInputDataCounterPrefix() {
    return _fixedInputDataCounterPrefix
        .toUint8List(); //Arrays.clone(fixedInputDataCounterPrefix);
  }

  Uint8List getFixedInputDataCounterSuffix() {
    return _fixedInputDataCounterSuffix
        .toUint8List(); //Arrays.clone(fixedInputDataCounterSuffix);
  }

  int getR() {
    return _r;
  }
}
