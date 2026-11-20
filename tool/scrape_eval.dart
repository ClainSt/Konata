import 'dart:convert';
import 'dart:io';

import 'scrape_eval_support.dart';

/// 刮削离线评测驱动：读取 `路径	字节数` 清单，经内存网关跑真实扫描器与归组拆分器，逐作品导出 JSONL。
///
/// 用法：`dart run tool/scrape_eval.dart <清单.tsv> <输出.jsonl> [--root=<扫描子目录>]`
Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('用法: dart run tool/scrape_eval.dart <清单.tsv> <输出.jsonl>');
    exitCode = 64;
    return;
  }
  final result = await groupListing(
    args[0],
    roots: [
      for (final a in args.skip(2))
        if (a.startsWith('--root=')) a.substring(7),
    ],
  );
  final sink = File(args[1]).openWrite();
  for (final g in result.groups) {
    sink.writeln(jsonEncode(dumpGroup(g)));
  }
  await sink.close();
  stderr.writeln(
    '扫描 ${result.files} 文件 ${result.scanMs}ms，归组 ${result.groups.length} 作品 ${result.groupMs}ms',
  );
}
