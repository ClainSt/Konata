import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// QQ 音乐逐字歌词密文解密器（纯内置定制块解密与标准压缩解压）。
///
/// 算法与标准块加密存在四处协议差异：
/// 1. 每 4 字节按小端字节序读入与写回；
/// 2. 第 2 替换盒 `[1][7]` 为 `15`、第 4 替换盒 `[3][5]` 为 `10`；
/// 3. 轮密钥后半段压缩置换采用下标减 27 偏移；
/// 4. 第 16 轮结束后不交换左右半块。
abstract final class QrcDecryptor {
  /// 协议固定 24 字节密钥原文。
  static const String _keyAscii = '!@#)(*\$%123ZXC!@!@#)(NHL';

  static final RegExp _hexRegex = RegExp(r'^[0-9a-fA-F]+$');

  static const List<int> _sbox1 = [
    14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7,
    0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8,
    4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0,
    15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13,
  ];
  static const List<int> _sbox2 = [
    15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10,
    3, 13, 4, 7, 15, 2, 8, 15, 12, 0, 1, 10, 6, 9, 11, 5,
    0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15,
    13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9,
  ];
  static const List<int> _sbox3 = [
    10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8,
    13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1,
    13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7,
    1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12,
  ];
  static const List<int> _sbox4 = [
    7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15,
    13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9,
    10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4,
    3, 15, 0, 6, 10, 10, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14,
  ];
  static const List<int> _sbox5 = [
    2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9,
    14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6,
    4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14,
    11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3,
  ];
  static const List<int> _sbox6 = [
    12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11,
    10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8,
    9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6,
    4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13,
  ];
  static const List<int> _sbox7 = [
    4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1,
    13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6,
    1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2,
    6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12,
  ];
  static const List<int> _sbox8 = [
    13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7,
    1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2,
    7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8,
    2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11,
  ];

  /// 判断输入字符串是否符合 8 字节块对齐的十六进制密文格式。
  static bool isValidCipherHex(String raw) {
    final trimmed = raw.trim();
    if (trimmed.length < 16 || trimmed.length % 16 != 0) return false;
    return _hexRegex.hasMatch(trimmed);
  }

  /// 将十六进制密文解密并经压缩流解压为文本；格式错误或解压失败返回 `null`。
  static String? decryptHex(String hexCipher) {
    final cleaned = hexCipher.trim();
    if (!isValidCipherHex(cleaned)) return null;
    try {
      final bytes = Uint8List(cleaned.length ~/ 2);
      for (var i = 0; i < bytes.length; i++) {
        bytes[i] = int.parse(cleaned.substring(i * 2, i * 2 + 2), radix: 16);
      }
      final keyBytes = Uint8List.fromList(ascii.encode(_keyAscii));
      final k0 = _buildKeySchedule(keyBytes, 16, encrypt: false);
      final k1 = _buildKeySchedule(keyBytes, 8, encrypt: true);
      final k2 = _buildKeySchedule(keyBytes, 0, encrypt: false);
      for (var off = 0; off + 8 <= bytes.length; off += 8) {
        _desCryptBlock(bytes, off, k0);
        _desCryptBlock(bytes, off, k1);
        _desCryptBlock(bytes, off, k2);
      }
      final inflated = zlib.decode(bytes);
      return utf8.decode(inflated, allowMalformed: true);
    } on Object {
      return null;
    }
  }

  /// 将明文文本经压缩流编码并按同构定制算法加密为十六进制串（供离线单元测试验真闭环使用）。
  static String encryptToHex(String plainText) {
    final compressed = zlib.encode(utf8.encode(plainText));
    final paddedLen = ((compressed.length + 7) ~/ 8) * 8;
    final buf = Uint8List(paddedLen)..setRange(0, compressed.length, compressed);
    final keyBytes = Uint8List.fromList(ascii.encode(_keyAscii));
    final enc0 = _buildKeySchedule(keyBytes, 0, encrypt: true);
    final enc1 = _buildKeySchedule(keyBytes, 8, encrypt: false);
    final enc2 = _buildKeySchedule(keyBytes, 16, encrypt: true);
    for (var off = 0; off + 8 <= buf.length; off += 8) {
      _desCryptBlock(buf, off, enc0);
      _desCryptBlock(buf, off, enc1);
      _desCryptBlock(buf, off, enc2);
    }
    final out = StringBuffer();
    for (final b in buf) {
      out.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return out.toString();
  }

  static int _bitnum(Uint8List a, int off, int b, int c) {
    return (((a[off + (b ~/ 32) * 4 + 3 - ((b % 32) ~/ 8)] >> (7 - (b % 8))) &
                1) <<
            c) &
        0xFFFFFFFF;
  }

  static int _bitnumIntr(int a, int b, int c) =>
      (((a >>> (31 - b)) & 1) << c) & 0xFF;

  static int _bitnumIntl(int a, int b, int c) =>
      ((((a << b) & 0x80000000) >>> c)) & 0xFFFFFFFF;

  static int _sboxBit(int a) => (a & 0x20) | ((a & 0x1F) >> 1) | ((a & 1) << 4);

  static List<Uint8List> _buildKeySchedule(
    Uint8List key,
    int keyOff, {
    required bool encrypt,
  }) {
    const shifts = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1];
    const permC = [
      56, 48, 40, 32, 24, 16, 8, 0, 57, 49, 41, 33, 25, 17, 9, 1,
      58, 50, 42, 34, 26, 18, 10, 2, 59, 51, 43, 35,
    ];
    const permD = [
      62, 54, 46, 38, 30, 22, 14, 6, 61, 53, 45, 37, 29, 21, 13, 5,
      60, 52, 44, 36, 28, 20, 12, 4, 27, 19, 11, 3,
    ];
    const comp = [
      13, 16, 10, 23, 0, 4, 2, 27, 14, 5, 20, 9, 22, 18, 11, 3, 25, 7, 15, 6, 26, 19, 12, 1,
      40, 51, 30, 36, 46, 54, 29, 39, 50, 44, 32, 47, 43, 48, 38, 55, 33, 52, 45, 41, 49, 35, 28, 31,
    ];
    var c = 0;
    var d = 0;
    for (var i = 0, j = 31; i < 28; i++, j--) {
      c |= _bitnum(key, keyOff, permC[i], j);
      d |= _bitnum(key, keyOff, permD[i], j);
    }
    final schedule = List<Uint8List>.generate(16, (_) => Uint8List(6));
    for (var i = 0; i < 16; i++) {
      final sh = shifts[i];
      c = (((c << sh) | (c >>> (28 - sh))) & 0xFFFFFFF0) & 0xFFFFFFFF;
      d = (((d << sh) | (d >>> (28 - sh))) & 0xFFFFFFF0) & 0xFFFFFFFF;
      final row = schedule[encrypt ? i : 15 - i];
      for (var j = 0; j < 24; j++) {
        row[j >> 3] |= _bitnumIntr(c, comp[j], 7 - (j & 7));
      }
      for (var j = 24; j < 48; j++) {
        row[j >> 3] |= _bitnumIntr(d, comp[j] - 27, 7 - (j & 7));
      }
    }
    return schedule;
  }

  static int _feistel(int state, Uint8List key) {
    final t1 = (_bitnumIntl(state, 31, 0) |
            ((state & 0xF0000000) >>> 1) |
            _bitnumIntl(state, 4, 5) |
            _bitnumIntl(state, 3, 6) |
            ((state & 0x0F000000) >>> 3) |
            _bitnumIntl(state, 8, 11) |
            _bitnumIntl(state, 7, 12) |
            ((state & 0x00F00000) >>> 5) |
            _bitnumIntl(state, 12, 17) |
            _bitnumIntl(state, 11, 18) |
            ((state & 0x000F0000) >>> 7) |
            _bitnumIntl(state, 16, 23)) &
        0xFFFFFFFF;
    final t2 = (_bitnumIntl(state, 15, 0) |
            (((state & 0x0000F000) << 15) & 0xFFFFFFFF) |
            _bitnumIntl(state, 20, 5) |
            _bitnumIntl(state, 19, 6) |
            (((state & 0x00000F00) << 13) & 0xFFFFFFFF) |
            _bitnumIntl(state, 24, 11) |
            _bitnumIntl(state, 23, 12) |
            (((state & 0x000000F0) << 11) & 0xFFFFFFFF) |
            _bitnumIntl(state, 28, 17) |
            _bitnumIntl(state, 27, 18) |
            (((state & 0x0000000F) << 9) & 0xFFFFFFFF) |
            _bitnumIntl(state, 0, 23)) &
        0xFFFFFFFF;
    final l0 = ((t1 >>> 24) & 0xFF) ^ key[0];
    final l1 = ((t1 >>> 16) & 0xFF) ^ key[1];
    final l2 = ((t1 >>> 8) & 0xFF) ^ key[2];
    final l3 = ((t2 >>> 24) & 0xFF) ^ key[3];
    final l4 = ((t2 >>> 16) & 0xFF) ^ key[4];
    final l5 = ((t2 >>> 8) & 0xFF) ^ key[5];
    final s = ((_sbox1[_sboxBit(l0 >> 2)] << 28) |
            (_sbox2[_sboxBit(((l0 & 0x03) << 4) | (l1 >> 4))] << 24) |
            (_sbox3[_sboxBit(((l1 & 0x0F) << 2) | (l2 >> 6))] << 20) |
            (_sbox4[_sboxBit(l2 & 0x3F)] << 16) |
            (_sbox5[_sboxBit(l3 >> 2)] << 12) |
            (_sbox6[_sboxBit(((l3 & 0x03) << 4) | (l4 >> 4))] << 8) |
            (_sbox7[_sboxBit(((l4 & 0x0F) << 2) | (l5 >> 6))] << 4) |
            _sbox8[_sboxBit(l5 & 0x3F)]) &
        0xFFFFFFFF;
    return (_bitnumIntl(s, 15, 0) |
            _bitnumIntl(s, 6, 1) |
            _bitnumIntl(s, 19, 2) |
            _bitnumIntl(s, 20, 3) |
            _bitnumIntl(s, 28, 4) |
            _bitnumIntl(s, 11, 5) |
            _bitnumIntl(s, 27, 6) |
            _bitnumIntl(s, 16, 7) |
            _bitnumIntl(s, 0, 8) |
            _bitnumIntl(s, 14, 9) |
            _bitnumIntl(s, 22, 10) |
            _bitnumIntl(s, 25, 11) |
            _bitnumIntl(s, 4, 12) |
            _bitnumIntl(s, 17, 13) |
            _bitnumIntl(s, 30, 14) |
            _bitnumIntl(s, 9, 15) |
            _bitnumIntl(s, 1, 16) |
            _bitnumIntl(s, 7, 17) |
            _bitnumIntl(s, 23, 18) |
            _bitnumIntl(s, 13, 19) |
            _bitnumIntl(s, 31, 20) |
            _bitnumIntl(s, 26, 21) |
            _bitnumIntl(s, 2, 22) |
            _bitnumIntl(s, 8, 23) |
            _bitnumIntl(s, 18, 24) |
            _bitnumIntl(s, 12, 25) |
            _bitnumIntl(s, 29, 26) |
            _bitnumIntl(s, 5, 27) |
            _bitnumIntl(s, 21, 28) |
            _bitnumIntl(s, 10, 29) |
            _bitnumIntl(s, 3, 30) |
            _bitnumIntl(s, 24, 31)) &
        0xFFFFFFFF;
  }

  static void _desCryptBlock(Uint8List buf, int off, List<Uint8List> schedule) {
    var s0 = (_bitnum(buf, off, 57, 31) |
            _bitnum(buf, off, 49, 30) |
            _bitnum(buf, off, 41, 29) |
            _bitnum(buf, off, 33, 28) |
            _bitnum(buf, off, 25, 27) |
            _bitnum(buf, off, 17, 26) |
            _bitnum(buf, off, 9, 25) |
            _bitnum(buf, off, 1, 24) |
            _bitnum(buf, off, 59, 23) |
            _bitnum(buf, off, 51, 22) |
            _bitnum(buf, off, 43, 21) |
            _bitnum(buf, off, 35, 20) |
            _bitnum(buf, off, 27, 19) |
            _bitnum(buf, off, 19, 18) |
            _bitnum(buf, off, 11, 17) |
            _bitnum(buf, off, 3, 16) |
            _bitnum(buf, off, 61, 15) |
            _bitnum(buf, off, 53, 14) |
            _bitnum(buf, off, 45, 13) |
            _bitnum(buf, off, 37, 12) |
            _bitnum(buf, off, 29, 11) |
            _bitnum(buf, off, 21, 10) |
            _bitnum(buf, off, 13, 9) |
            _bitnum(buf, off, 5, 8) |
            _bitnum(buf, off, 63, 7) |
            _bitnum(buf, off, 55, 6) |
            _bitnum(buf, off, 47, 5) |
            _bitnum(buf, off, 39, 4) |
            _bitnum(buf, off, 31, 3) |
            _bitnum(buf, off, 23, 2) |
            _bitnum(buf, off, 15, 1) |
            _bitnum(buf, off, 7, 0)) &
        0xFFFFFFFF;
    var s1 = (_bitnum(buf, off, 56, 31) |
            _bitnum(buf, off, 48, 30) |
            _bitnum(buf, off, 40, 29) |
            _bitnum(buf, off, 32, 28) |
            _bitnum(buf, off, 24, 27) |
            _bitnum(buf, off, 16, 26) |
            _bitnum(buf, off, 8, 25) |
            _bitnum(buf, off, 0, 24) |
            _bitnum(buf, off, 58, 23) |
            _bitnum(buf, off, 50, 22) |
            _bitnum(buf, off, 42, 21) |
            _bitnum(buf, off, 34, 20) |
            _bitnum(buf, off, 26, 19) |
            _bitnum(buf, off, 18, 18) |
            _bitnum(buf, off, 10, 17) |
            _bitnum(buf, off, 2, 16) |
            _bitnum(buf, off, 60, 15) |
            _bitnum(buf, off, 52, 14) |
            _bitnum(buf, off, 44, 13) |
            _bitnum(buf, off, 36, 12) |
            _bitnum(buf, off, 28, 11) |
            _bitnum(buf, off, 20, 10) |
            _bitnum(buf, off, 12, 9) |
            _bitnum(buf, off, 4, 8) |
            _bitnum(buf, off, 62, 7) |
            _bitnum(buf, off, 54, 6) |
            _bitnum(buf, off, 46, 5) |
            _bitnum(buf, off, 38, 4) |
            _bitnum(buf, off, 30, 3) |
            _bitnum(buf, off, 22, 2) |
            _bitnum(buf, off, 14, 1) |
            _bitnum(buf, off, 6, 0)) &
        0xFFFFFFFF;
    for (var i = 0; i < 15; i++) {
      final t = s1;
      s1 = (_feistel(s1, schedule[i]) ^ s0) & 0xFFFFFFFF;
      s0 = t;
    }
    s0 = (_feistel(s1, schedule[15]) ^ s0) & 0xFFFFFFFF;

    int invByte(int bit) =>
        _bitnumIntr(s1, bit, 7) |
        _bitnumIntr(s0, bit, 6) |
        _bitnumIntr(s1, bit + 8, 5) |
        _bitnumIntr(s0, bit + 8, 4) |
        _bitnumIntr(s1, bit + 16, 3) |
        _bitnumIntr(s0, bit + 16, 2) |
        _bitnumIntr(s1, bit + 24, 1) |
        _bitnumIntr(s0, bit + 24, 0);

    buf[off + 3] = invByte(7);
    buf[off + 2] = invByte(6);
    buf[off + 1] = invByte(5);
    buf[off + 0] = invByte(4);
    buf[off + 7] = invByte(3);
    buf[off + 6] = invByte(2);
    buf[off + 5] = invByte(1);
    buf[off + 4] = invByte(0);
  }
}
