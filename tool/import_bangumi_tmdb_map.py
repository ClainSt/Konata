"""把 Wikidata 的 Bangumi 条目 ID ↔ TMDB 剧集/电影 ID 映射快照转换为领域层 Dart 常量查表。

快照获取（Wikidata 查询服务，结果为 CC0-1.0）：
    https://query.wikidata.org/sparql 以 `Accept: text/csv` 执行
    SELECT ?item ?bgm ?tv ?movie WHERE {
      ?item wdt:P5732 ?bgm .
      OPTIONAL { ?item wdt:P4983 ?tv }
      OPTIONAL { ?item wdt:P4947 ?movie }
    }
用法: python tool/import_bangumi_tmdb_map.py path/to/bangumi_tmdb.csv
本脚本只做离线转换：不联网、不执行外部表达式，仅保留纯数字 ID。
"""
import csv
import hashlib
from pathlib import Path
import sys

DESTINATION = Path(__file__).resolve().parent.parent / 'lib' / 'domain' / 'scraping' / 'bangumi_tmdb_map.dart'

TEMPLATE = '''// 由 tool/import_bangumi_tmdb_map.py 自动生成，请勿手动修改映射表。
// 数据来源：Wikidata（P5732 Bangumi 条目 ID ↔ P4983 TMDB 剧集 ID / P4947 TMDB 电影 ID）。
// 许可协议：CC0-1.0（详见 assets/licenses/wikidata-cc0.txt）。
// 快照 SHA-256：__SHA__
// 共 __COUNT__ 个 Bangumi 条目；仅作为跨源打分加权与锚定依据，不直接决定绑定结果。
import '../models/work.dart';

/// Bangumi 条目 ID 到 TMDB 剧集/电影 ID 的离线映射查表（来自 Wikidata 公有领域数据）。
abstract final class BangumiTmdbMap {
  /// 返回 Bangumi 条目对应的全部 TMDB 目标（无映射时为空列表）。
  static List<({TmdbMediaType type, int id})> lookup(int bangumiId) {
    final encoded = _index[bangumiId];
    if (encoded == null) return const [];
    return [
      for (final token in encoded.split(','))
        (
          type: token.startsWith('m') ? TmdbMediaType.movie : TmdbMediaType.tv,
          id: int.parse(token.substring(1)),
        ),
    ];
  }

  /// 编码：`t<ID>` 为 TMDB 剧集，`m<ID>` 为 TMDB 电影，多个目标以逗号分隔。
  static const Map<int, String> _index = {
__BODY__
  };
}
'''


def generate(source: Path, destination: Path):
    data = source.read_bytes()
    if len(data) > 8 * 1024 * 1024:
        raise ValueError('映射快照超过 8 MiB，拒绝转换')
    mapping = {}
    for row in csv.DictReader(data.decode('utf-8-sig').splitlines()):
        bgm = (row.get('bgm') or '').strip()
        if not bgm.isdigit():
            continue
        targets = mapping.setdefault(int(bgm), set())
        for column, prefix in (('tv', 't'), ('movie', 'm')):
            value = (row.get(column) or '').strip()
            if value.isdigit():
                targets.add(f'{prefix}{int(value)}')
    entries = [(bgm, ','.join(sorted(t))) for bgm, t in sorted(mapping.items()) if t]
    body = '\n'.join(f"    {bgm}: '{targets}'," for bgm, targets in entries)
    text = (TEMPLATE.replace('__SHA__', hashlib.sha256(data).hexdigest())
            .replace('__COUNT__', str(len(entries)))
            .replace('__BODY__', body))
    destination.write_text(text, encoding='utf-8', newline='\n')
    return len(entries)


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8')
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(64)
    count = generate(Path(sys.argv[1]), DESTINATION)
    print(f'已生成 {DESTINATION.name}：{count} 个 Bangumi 条目')
