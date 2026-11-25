import 'dart:convert';
import 'dart:typed_data';

import '../text/playback_table_assets.dart';

/// 经编译期打包的标准 OpenCC 繁简转换词典集合（Apache-2.0 OpenCC 词库，惰性按需加载）。
///
/// 核心保障：
/// - `TSCharacters`（繁转简单字）覆盖 4159 个标准条目（含异体与扩展区汉字）；
/// - `STCharacters`（简转繁单字）独立维护 4012 个定向条目，严禁由 `TSCharacters` 简单反转冒充；
/// - `TSPhrases`（438 条）与 `STPhrases`（9823 条）配合最长前向匹配（FMM），
///   完整解决 `後/后`、`裡/裏/里`、`隻/只`、`鬥/斗`、`鐘/鍾/钟`、`闆/板`、`醜/丑`、`戀/恋`、`乾/幹/干`、`髮/發/发` 等多义消歧。
abstract final class OpenCcDictionaries {
  /// 标准繁转简单字映射条目数。
  static const int tsCharacterCount = 4159;

  /// 标准简转繁独立单字映射条目数。
  static const int stCharacterCount = 4012;

  /// 标准繁转简词组消歧条目数。
  static const int tsPhraseCount = 438;

  /// 标准简转繁词组消歧条目数。
  static const int stPhraseCount = 9823;

  static final _asset = PlaybackTableAsset('opencc_dict.bin.gz');
  static List<Uint8List>? _sections;
  static _OpenCcCompiledBundle? _traditionalToSimplified;
  static _OpenCcCompiledBundle? _simplifiedToTraditional;

  /// 词表是否已经读取或解码。
  static bool get isLoaded => _asset.isLoaded;

  /// 从宿主按需取得压缩词表，后台隔离线程可复用这份源数据。
  static Future<Uint8List> prepare() => _asset.prepare();

  /// 在后台隔离线程中接收宿主已经读取的压缩词表。
  static void usePrepared(Uint8List bytes) => _asset.usePrepared(bytes);

  /// 播放退出后释放压缩源与已解析映射。
  static void release() {
    _asset.release();
    _sections = null;
    _traditionalToSimplified = null;
    _simplifiedToTraditional = null;
  }

  static _OpenCcCompiledBundle get _tsBundle =>
      _traditionalToSimplified ??= _readBundle(0);

  static _OpenCcCompiledBundle get _stBundle =>
      _simplifiedToTraditional ??= _readBundle(2);

  static _OpenCcCompiledBundle _readBundle(int index) {
    final sections = _sections ??= PlaybackTableAssets.decodeSections(
      _asset.bytes,
      'KOC1',
      4,
    );
    return _OpenCcCompiledBundle.fromBytes(
      charsBytes: sections[index],
      phrasesBytes: sections[index + 1],
    );
  }

  /// 执行基于标准 OpenCC 词库的最长前向匹配（FMM）繁简转换。
  static String convert(String text, {required bool toSimplified}) {
    if (text.isEmpty) return text;
    final bundle = toSimplified ? _tsBundle : _stBundle;
    return bundle.convert(text);
  }

  /// 获取繁转简单字只读映射（供单测核验词库规模与映射方向性）。
  static Map<int, String> get tsChars => _tsBundle.charMap;

  /// 获取简转繁单字只读映射（供单测核验非简单反转）。
  static Map<int, String> get stChars => _stBundle.charMap;

  /// 获取繁转简词组只读映射。
  static Map<String, String> get tsPhrases => _tsBundle.phraseMap;

  /// 获取简转繁词组只读映射。
  static Map<String, String> get stPhrases => _stBundle.phraseMap;
}

class _OpenCcCompiledBundle {
  _OpenCcCompiledBundle({
    required this.charMap,
    required this.phraseMap,
    required this.phraseFirstRunes,
    required this.maxPhraseRunes,
  });

  factory _OpenCcCompiledBundle.fromBytes({
    required Uint8List charsBytes,
    required Uint8List phrasesBytes,
  }) {
    final chars = <int, String>{};
    final charLines = utf8.decode(charsBytes).split('\n');
    for (final line in charLines) {
      final tab = line.indexOf('\t');
      if (tab <= 0) continue;
      final key = line.substring(0, tab);
      final val = line.substring(tab + 1);
      final runes = key.runes.toList(growable: false);
      if (runes.length == 1) {
        chars[runes.first] = val;
      }
    }

    final phrases = <String, String>{};
    final firstRunes = <int>{};
    var maxLen = 1;
    final lines = utf8.decode(phrasesBytes).split('\n');
    for (final line in lines) {
      final tab = line.indexOf('\t');
      if (tab <= 0) continue;
      final key = line.substring(0, tab);
      final val = line.substring(tab + 1);
      final runeLen = key.runes.length;
      if (runeLen < 2) continue;
      phrases[key] = val;
      firstRunes.add(key.runes.first);
      if (runeLen > maxLen) {
        maxLen = runeLen;
      }
    }

    return _OpenCcCompiledBundle(
      charMap: Map<int, String>.unmodifiable(chars),
      phraseMap: Map<String, String>.unmodifiable(phrases),
      phraseFirstRunes: firstRunes,
      maxPhraseRunes: maxLen,
    );
  }

  final Map<int, String> charMap;
  final Map<String, String> phraseMap;
  final Set<int> phraseFirstRunes;
  final int maxPhraseRunes;

  /// 按 Unicode 码点执行最长前向词组优先匹配，命中的词组直出不再二次过单字表。
  String convert(String input) {
    final runes = input.runes.toList(growable: false);
    final n = runes.length;
    if (n == 0) return input;
    final out = StringBuffer();
    var i = 0;
    while (i < n) {
      final first = runes[i];
      var matched = false;
      if (maxPhraseRunes >= 2 && phraseFirstRunes.contains(first)) {
        final upper = (n - i) < maxPhraseRunes ? (n - i) : maxPhraseRunes;
        for (var len = upper; len >= 2; len--) {
          final candidate = String.fromCharCodes(runes, i, i + len);
          final replacement = phraseMap[candidate];
          if (replacement != null) {
            out.write(replacement);
            i += len;
            matched = true;
            break;
          }
        }
      }
      if (!matched) {
        final mapped = charMap[first];
        if (mapped != null) {
          out.write(mapped);
        } else {
          out.writeCharCode(first);
        }
        i += 1;
      }
    }
    return out.toString();
  }
}
