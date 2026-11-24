"""Convert a reviewed FileBot CC0 snapshot into a bounded literal Dart lookup.

Usage: python tool/import_release_groups.py path/to/release-groups.txt
No network, runtime regex from external data, or automatic updates.
"""
import hashlib
from pathlib import Path
import re
import sys


def generate(source: Path, destination: Path):
    data = source.read_bytes()
    if len(data) > 128 * 1024:
        raise ValueError('Release group snapshot exceeds 128 KiB')
    insensitive, sensitive = set(), set()
    for line in data.decode('utf-8-sig').splitlines():
        line = line.strip()
        if not line:
            continue
        if line.startswith('(?-i:') and line.endswith(')'):
            values = line[5:-1].split('|')
            if not all(re.fullmatch(r'[A-Za-z0-9_-]+', v) for v in values):
                raise ValueError('Unsupported case-sensitive expression')
            sensitive.update(values)
        else:
            line = line.replace(r'\[', '[').replace(r'\]', ']')
            if any(c in line for c in '\\()|?*^${}') or "'''" in line:
                raise ValueError(f'Unsupported expression: {line}')
            insensitive.add(line.lower())
    text = '\n'.join(sorted(insensitive))
    exact = ', '.join(repr(v) for v in sorted(sensitive))
    destination.write_text(f'''// 由 tool/import_release_groups.py 自动生成，请勿手动修改字幕组词表。
// 数据来源：https://github.com/filebot/data/blob/master/release-groups.txt
// 许可协议：CC0-1.0（详见 assets/licenses/filebot-data.txt）。
// 词表快照 SHA-256：{hashlib.sha256(data).hexdigest()}
// 仅独立发行标签可作为字幕组剔除；已确认的作品别名优先级更高。
abstract final class ReleaseGroups {{
  static final _names = _data.split('\\n').toSet();
  static const _caseSensitive = <String>{{{exact}}};
  static bool contains(String value) =>
      // 结合该字幕组官方字幕仓库核验补充的别名：
      // 仓库地址：https://github.com/Nekomoekissaten-SUB/Nekomoekissaten-Subs
      value.trim().toLowerCase() == 'nekomoe kissaten' ||
      // 结合本地 129 份命名基准样板核验的精确复合标签；
      // 禁止仅凭 '&' 或局部子串推断字幕组归属。
      value.trim().toLowerCase() == 'txxz&a.i.r.nessub' ||
      _caseSensitive.contains(value.trim()) ||
      _names.contains(value.trim().toLowerCase());
  static const _data = r\'''{text}\''';
}}
''', encoding='utf-8')
    print(f'{len(insensitive)} folded + {len(sensitive)} exact names; '
          f'{destination.stat().st_size} Dart source bytes')


if __name__ == '__main__':
    root = Path(__file__).resolve().parents[1]
    generate(
        Path(sys.argv[1]),
        root
        / 'packages/engines/engine_scraping/lib/src/parsing/release_groups.dart',
    )
