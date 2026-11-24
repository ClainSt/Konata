import 'dart:typed_data';

import 'package:pointycastle/export.dart';
import 'package:smb_connect/src/utils/extensions.dart';

/// 对称分组密码核心调度器：统一封装 ECB/CFB/OFB/CBC/PCBC/CTR/CTS 工作模式及填充方案。
///
class DESCipherInternal implements StreamCipher {
  /// 加解密分块对齐期间使用的内部字节暂存缓冲区。
  late Uint8List buffer;

  /// 当前对称算法单个分组的字节宽度。
  int blockSize = 0;

  /// 每次流/分组步进可处理的输入单位字节数。
  int unitBytes = 0;

  /// 内部缓冲区中当前尚余有效未处理字节长度。
  int buffered = 0;

  /// 执行末块 `encryptFinal/decryptFinal` 前缓冲区必须保留的最小输入字节数（如 CTS 末两块）。
  int minBytes = 0;

  /// 使累计输入长度成为分组整数倍尚需补齐的差额字节数。
  int diffBlocksize = 0;

  /// 数据末块填充（Padding）策略实现对象。
  Padding? padding;

  /// 底层对称加密/解密引擎具体实现。
  ECBBlockCipher? cipher;

  /// 当前配置的对称密码工作模式编号。
  int cipherMode = ECB_MODE;

  /// 指示当前处于解密方向还是加密方向。
  bool decrypting = false;

  @override
  String get algorithmName => throw UnimplementedError();

  /// 对称密码工作模式常量定义组。
  static const int ECB_MODE = 0;
  static const int CBC_MODE = 1;
  static const int CFB_MODE = 2;
  static const int OFB_MODE = 3;
  static const int PCBC_MODE = 4;
  static const int CTR_MODE = 5;
  static const int CTS_MODE = 6;

  /// 构造默认 ECB 模式且带 PKCS5 填充的分组密码核心实例；预留至少 `blockSize+1` 缓冲区以适配 CTS 与解密去填。
  DESCipherInternal(BlockCipher impl, int blkSize) {
    blockSize = blkSize;
    unitBytes = blkSize;
    diffBlocksize = blkSize;


    buffer = Uint8List(blockSize * 2); // new byte[blockSize*2];

    cipher = ECBBlockCipher(impl); //ElectronicCodeBook(impl);
  }

  static int getNumOfUnit(String mode, int offset, int blockSize) {
    int result = blockSize; // use blockSize as default value
    if (mode.length > offset) {
      final numInt = int.tryParse(mode.substring(offset));
      if (numInt == null) {
        throw Exception("Algorithm mode: $mode not implemented");
      }
      result = numInt >> 3;
      if ((numInt % 8 != 0) || (result > blockSize)) {
        throw Exception("Invalid algorithm mode: $mode");
      }
    }
    return result;
  }

  ///
  /// 使用指定密钥、算法参数（如 IV）及随机源初始化当前加解密上下文。
  ///
  ///
  ///
  ///
  @override
  void init(bool forEncryption, CipherParameters? key) {
    decrypting = !forEncryption;
    // }

    //                 }
    //                 }
    //             }
    //         }
    //             }
    //             }

    //             }

    //         }

    buffered = 0;
    diffBlocksize = blockSize;

    cipher!.init(forEncryption, key);
  }

  /// 分段流式加解密更新接口：处理输入切片 `[inputOffset, inputOffset+inputLen)` 并写入 `output`。
  ///
  ///
  ///
  ///
  @override
  void processBytes(
      Uint8List inp, int inpOff, int len0, Uint8List out, int outOff) {
    //     }

    //     }

    //         }
    //             }
    //             }
    //                     }
    //                 }
    //                 }
    //             }
    //                 }
    //             }
    //         }
    //             }
    //         }
    //     }
    //     }
  }

  ///
  /// 完成单次或分段末块加解密处理（自动应用或校验去除 Padding，并返回最终输出字节数组）。
  ///
  ///
  ///
  ///
  ///
  @override
  Uint8List process(Uint8List data) {
    Uint8List output = Uint8List(data.length);
    var finalBuf = prepareInputBuffer(data, 0, data.length, output, 0);
    fillOutputBuffer(finalBuf, 0, output, 0, output.length, data);


    endDoFinal();
    //             }
    //         }
    //     }
    return output;
  }

  void endDoFinal() {
    buffered = 0;
    diffBlocksize = blockSize;
    if (cipherMode != ECB_MODE) {
      cipher?.reset();
    }
  }

  @override
  void reset() {
  }

  @override
  int returnByte(int inp) {
    throw UnimplementedError();
  }

  Uint8List prepareInputBuffer(Uint8List input, int inputOffset, int inputLen,
      Uint8List output, int outputOffset) {
    // 计算总输入与内部残留缓存合计字节数。
    int len = buffered + inputLen;
    // 计算末块补齐所需的填充字节数。
    int totalLen = len;
    int paddingLen = 0;
    // 检查总输入长度是否恰好对齐分组整数倍。
    if (unitBytes != blockSize) {
      if (totalLen < diffBlocksize) {
        paddingLen = diffBlocksize - totalLen;
      } else {
        paddingLen = blockSize - ((totalLen - diffBlocksize) % blockSize);
      }
    } else if (padding != null) {
      paddingLen = padding!.padCount(input); // padLength(totalLen);
    }

    if (decrypting &&
        (padding != null) &&
        (paddingLen > 0) &&
        (paddingLen != blockSize)) {
      throw Exception(
          "Input length must be multiple of $blockSize when decrypting with padded cipher"); //IllegalBlockSizeException
    }

    ///
    /// 当输入输出缓冲区重叠、内部有缓存在途字节或需加密填充时，重组最终连续处理缓冲区；用毕立即清零敏感暂存区。

    if ((buffered != 0) ||
        (!decrypting && padding != null) ||
        ((input == output) &&
            (outputOffset - inputOffset < inputLen) &&
            (inputOffset - outputOffset < buffer.length))) {
      Uint8List finalBuf;
      if (decrypting || padding == null) {
        paddingLen = 0;
      }
      finalBuf = Uint8List(len + paddingLen);
      if (buffered != 0) {
        byteArrayCopy(
            src: buffer,
            srcOffset: 0,
            dst: finalBuf,
            dstOffset: 0,
            length: buffered);
        if (!decrypting) {
          // 加密模式下处理完成后立即擦除内部输入缓存，避免敏感明文残留在内存中。
          buffer.fill();
        }
      }
      if (inputLen != 0) {
        byteArrayCopy(
            src: input,
            srcOffset: 0,
            dst: finalBuf,
            dstOffset: buffered,
            length: inputLen);
      }
      if (paddingLen != 0) {
      }
      return finalBuf;
    }
    return input;
  }

  int fillOutputBuffer(Uint8List finalBuf, int finalOffset, Uint8List output,
      int outOfs, int finalBufLen, Uint8List input) {
    int len;
    try {
      len = finalNoPadding(finalBuf, finalOffset, output, outOfs, finalBufLen);
      if (decrypting && padding != null) {
      }
      return len;
    } finally {
      if (!decrypting && finalBuf != input) {
        // 末块数据已完整写出至结果缓冲区，收尾清理内部缓冲状态。
        finalBuf.fill();
      }
    }
  }

  int finalNoPadding(
      Uint8List? inp, int inOfs, Uint8List out, int outOfs, int len) {
    if (inp == null || len == 0) {
      return 0;
    }
    if ((cipherMode != CFB_MODE) &&
        (cipherMode != OFB_MODE) &&
        ((len % unitBytes) != 0) &&
        (cipherMode != CTS_MODE)) {
      if (padding != null) {
        throw Exception(
            "Input length (with padding) not multiple of $unitBytes bytes"); //IllegalBlockSizeException
      } else {
        throw Exception(
            "Input length not multiple of $unitBytes bytes"); //IllegalBlockSizeException
      }
    }

    for (int i = len; i >= blockSize; i -= blockSize) {
      cipher!.processBlock(inp, inOfs, out, outOfs);
      inOfs += blockSize;
      outOfs += blockSize;
    }
    return len;
  }
}
