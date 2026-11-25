import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const _sourceRevision = 'f0276ca';
const _scraping = 'packages/engines/engine_scraping/lib/src';
const _playback = 'packages/engines/engine_playback/lib/src/domain';
const _library = 'packages/features/feature_library/lib/src/data';

void main(List<String> args) {
  if (args.isNotEmpty && (args.length != 1 || args.single != '--check')) {
    stderr.writeln('用法：dart run tool/build_data_tables.dart [--check]');
    exitCode = 64;
    return;
  }
  final check = args.isNotEmpty;
  final root = File.fromUri(Platform.script).parent.parent;
  final output = Directory.fromUri(
    root.uri.resolve('apps/konata/assets/data/'),
  );
  final groupsSource = _source(root, '$_scraping/parsing/release_groups.dart');
  final groups = RegExp(
    "static const _data = r'''([\\s\\S]*?)'''",
  ).firstMatch(groupsSource)?.group(1);
  if (groups == null || groups.isEmpty) {
    throw const FormatException('未识别发行组原始词表');
  }

  final openCcSource = _source(
    root,
    '$_playback/playback/opencc_dictionaries.dart',
  );
  final assets = <String, List<int>>{
    'release_groups.bin.gz': utf8.encode(groups),
    'opencc_dict.bin.gz': _sections('KOC1', [
      _base64Literal(openCcSource, '_tsCharsBase64'),
      _base64Literal(openCcSource, '_tsPhrasesBase64'),
      _base64Literal(openCcSource, '_stCharsBase64'),
      [
        ..._table(
          root,
          '$_playback/playback/opencc_st_phrases_part1.dart',
          '_openCcStPhrasesPart1Base64',
        ),
        0x0a,
        ..._table(
          root,
          '$_playback/playback/opencc_st_phrases_part2.dart',
          '_openCcStPhrasesPart2Base64',
        ),
      ],
    ]),
    'pinyin.bin.gz': _table(
      root,
      '$_library/chinese_pinyin_table.dart',
      'chinesePinyinRankTableBase64',
    ),
  };
  if (assets['pinyin.bin.gz']!.length != 20902) {
    throw const FormatException('拼音词表没有覆盖全部基本汉字');
  }

  if (!check) output.createSync(recursive: true);
  final codec = GZipCodec(level: 9);
  void emit(String name, int sourceBytes, List<int> compressed) {
    final target = File.fromUri(output.uri.resolve(name));
    if (check) {
      if (!target.existsSync() ||
          !_equalBytes(target.readAsBytesSync(), compressed)) {
        stderr.writeln('$name 与原始词表生成结果不一致');
        exitCode = 1;
        return;
      }
    } else {
      target.writeAsBytesSync(compressed, flush: true);
    }
    stdout.writeln('$name · $sourceBytes → ${compressed.length} 字节');
  }

  for (final entry in assets.entries) {
    emit(entry.key, entry.value.length, codec.encode(entry.value));
  }
  final pages = [
    _table(root, '$_playback/text/gbk_cp936_table.dart', '_payloadBase64'),
    _table(root, '$_playback/text/big5_cp950_table.dart', '_packedBase64'),
    _table(
      root,
      '$_playback/text/shift_jis_cp932_table.dart',
      '_payloadBase64',
    ),
  ];
  final codepages = BytesBuilder(copy: false);
  var codepageSize = 0;
  for (final page in pages) {
    codepageSize += page.length;
    codepages.add(_gzipMember(codec.encode(page)));
  }
  emit('legacy_codepages.bin.gz', codepageSize, codepages.takeBytes());
}

/// 每页独立压缩，在标准 gzip 扩展字段中写入成员长度供解码器跳过其余页。
Uint8List _gzipMember(List<int> compressed) {
  if (compressed.length < 18 || compressed[3] != 0) {
    throw const FormatException('旧编码压缩头不是预期的固定格式');
  }
  final header = Uint8List.fromList(compressed.sublist(0, 10));
  header[3] = 4;
  final extra = ByteData(10)
    ..setUint16(0, 8, Endian.little)
    ..setUint8(2, 0x4b)
    ..setUint8(3, 0x50)
    ..setUint16(4, 4, Endian.little)
    ..setUint32(6, compressed.length + 10, Endian.little);
  return (BytesBuilder(copy: false)
        ..add(header)
        ..add(extra.buffer.asUint8List())
        ..add(compressed.sublist(10)))
      .takeBytes();
}

String _source(Directory root, String path) {
  final result = Process.runSync(
    'git',
    ['show', '$_sourceRevision:$path'],
    workingDirectory: root.path,
    stdoutEncoding: utf8,
  );
  if (result.exitCode != 0) {
    throw StateError('无法读取固定版本词表 $path：${result.stderr}');
  }
  return (result.stdout as String).replaceAll('\r\n', '\n');
}

List<int> _table(Directory root, String path, String name) =>
    _base64Literal(_source(root, path), name);

Uint8List _base64Literal(String source, String name) {
  final match = RegExp(
    '\\b${RegExp.escape(name)}\\s*=\\s*((?:\'[A-Za-z0-9+/=]+\'\\s*)+);',
  ).firstMatch(source);
  if (match == null) throw FormatException('未识别原始数据段 $name');
  final parts = RegExp("'([A-Za-z0-9+/=]+)'").allMatches(match.group(1)!);
  return base64Decode(parts.map((part) => part.group(1)!).join());
}

/// 固定魔数和长度表可区分版本，并为解码器提供稳定数据段边界。
Uint8List _sections(String magic, List<List<int>> sections) {
  final lengths = ByteData(4 * sections.length);
  for (var i = 0; i < sections.length; i++) {
    lengths.setUint32(i * 4, sections[i].length, Endian.little);
  }
  final result = BytesBuilder(copy: false)
    ..add(ascii.encode(magic))
    ..add(lengths.buffer.asUint8List());
  for (final section in sections) {
    result.add(section);
  }
  return result.takeBytes();
}

bool _equalBytes(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var i = 0; i < left.length; i++) {
    if (left[i] != right[i]) return false;
  }
  return true;
}
