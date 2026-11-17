import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/api.dart';
import 'package:smb_connect/src/utils/extensions.dart';

import 'kdf_counter_parameters.dart';

/// 基于公开标准 NIST SP 800-108 计数器模式的密钥派生生成器（支持前置/中置/后置计数 counter 布局）。
/// <ul>
/// </ul>
/// <ul>
///  <li>KI</li>
/// </ul>
/// <ul>
/// </ul>
class KDFCounterBytesGenerator {
  static const int MAX_VALUE = 0x7fffffff;
  static final BigInt INTEGER_MAX = BigInt.from(MAX_VALUE);

  // 构造函数初始化的底层 PRF 引擎与计数位宽配置字段。
  final Mac prf;
  final int h;
  // `init()` 阶段设定的种子密钥与固定前缀/后缀输入字节。
  Uint8List? _fixedInputDataCtrPrefix;
  Uint8List? _fixedInputDataAfterCtr;
  int maxSizeExcl = 0;
  // 用于编码大端字节序迭代计数器 `i` 的临时缓冲区。
  late Uint8List _ios;
  // 密钥派生循环运行期内部游标与当前块状态。
  int _generatedBytes = 0;
  // 暂存单轮 PRF 输出密钥材料 `K(i)` 的临时数组。
  final Uint8List _k;

  KDFCounterBytesGenerator(this.prf)
      : h = prf.macSize,
        _k = Uint8List(prf.macSize);

  void init(KDFCounterParameters param) {
    //     {
    //     }

    KDFCounterParameters kdfParams = param; //(KDFCounterParameters)param;

    // 初始化基于 HMAC-SHA256 的伪随机函数 MAC 密钥。

    prf.init(KeyParameter(kdfParams.getKI()));

    // 设定派生计数器位宽并检查衍生长度不超过 `2^r * h` 上限。

    _fixedInputDataCtrPrefix = kdfParams.getFixedInputDataCounterPrefix();
    _fixedInputDataAfterCtr = kdfParams.getFixedInputDataCounterSuffix();

    int r = kdfParams.getR();
    _ios = Uint8List(r ~/ 8);

    BigInt maxSize = BigInt.two.pow(r) * BigInt.from(h);
    maxSizeExcl =
        maxSize.compareTo(INTEGER_MAX) == 1 ? MAX_VALUE : maxSize.toInt();

    // 清零迭代步长游标与输出偏移状态。

    _generatedBytes = 0;
  }

  int generateBytes(Uint8List out, int outOff, int len) {
    int generatedBytesAfter = _generatedBytes + len;
    if (generatedBytesAfter < 0 || generatedBytesAfter >= maxSizeExcl) {
      throw "Current KDFCTR may only be used for $maxSizeExcl bytes";
    }

    if (_generatedBytes % h == 0) {
      _generateNext();
    }

    // 先搬运上一轮派生缓冲区 `k` 内尚余的未消费字节，随后按需计算下一轮 `K(i)`。
    int toGenerate = len;
    int posInK = _generatedBytes % h;
    int leftInK = h - _generatedBytes % h;
    int toCopy = min(leftInK, toGenerate);
    arrayCopy(_k, posInK, out, outOff, toCopy);
    _generatedBytes += toCopy;
    toGenerate -= toCopy;
    outOff += toCopy;

    while (toGenerate > 0) {
      _generateNext();
      toCopy = min(h, toGenerate);
      arrayCopy(_k, 0, out, outOff, toCopy);
      _generatedBytes += toCopy;
      toGenerate -= toCopy;
      outOff += toCopy;
    }

    return len;
  }

  void _generateNext() {
    int i = _generatedBytes ~/ h + 1;

    // 将轮次序号 `i` 按大端字节序写入计数器缓冲区 `ios`。
    switch (_ios.length) {
      case 4:
        _ios[0] = (i >>> 24);
        _ios[_ios.length - 3] = (i >>> 16);
        _ios[_ios.length - 2] = (i >>> 8);
        _ios[_ios.length - 1] = i;
      // 依序穿透执行后续低位计数器字节填充分支。
      case 3:
        _ios[_ios.length - 3] = (i >>> 16);
        _ios[_ios.length - 2] = (i >>> 8);
        _ios[_ios.length - 1] = i;
      // 依序穿透执行后续低位计数器字节填充分支。
      case 2:
        _ios[_ios.length - 2] = (i >>> 8);
        _ios[_ios.length - 1] = i;
      // 依序穿透执行后续低位计数器字节填充分支。
      case 1:
        _ios[_ios.length - 1] = i;
        break;
      default:
        throw "Unsupported size of counter i";
    }

    // 特例：`K(0)` 为空串，首次派生从计数器 1 启动并按前缀/计数/后缀喂入 PRF。
    prf.update(_fixedInputDataCtrPrefix!, 0, _fixedInputDataCtrPrefix!.length);
    prf.update(_ios, 0, _ios.length);
    prf.update(_fixedInputDataAfterCtr!, 0, _fixedInputDataAfterCtr!.length);
    prf.doFinal(_k, 0);
  }
}
