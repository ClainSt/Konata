"""离线编译 Bangumi ↔ TMDB 映射快照（支持 Wikidata CSV 与 open-ani/bangumi-tmdb 紧凑二进制表）。

本脚本支持两种模式：
1. 传统 Wikidata CSV 模式（生成 Dart 静态查表 `lib/domain/scraping/bangumi_tmdb_map.dart`）：
   python tool/import_bangumi_tmdb_map.py path/to/bangumi_tmdb.csv

2. 全量紧凑二进制模式（合并 open-ani/bangumi-tmdb + 内置 Wikidata CC0，产出 `bangumi_tmdb_map.bin` 与 `manifest.json`）：
   python tool/import_bangumi_tmdb_map.py --build-binary \
     --open-ani path/to/subjects.json \
     --open-ani-manifest path/to/manifest.json \
     --out-bin assets/data/bangumi_tmdb_map.bin \
     --out-manifest assets/data/bangumi_tmdb_manifest.json

3. 在线拉取最新 open-ani/bangumi-tmdb Release 并编译（供 GitHub Actions `sync-mapping` 使用）：
   python tool/import_bangumi_tmdb_map.py --build-binary --fetch-open-ani \
     --out-bin dist/bangumi_tmdb_map.bin \
     --out-manifest dist/manifest.json
"""
import argparse
import csv
import datetime
import hashlib
import json
import re
import struct
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WIKIDATA_DART = ROOT / 'lib' / 'domain' / 'scraping' / 'bangumi_tmdb_map.dart'
DEFAULT_OUT_BIN = ROOT / 'assets' / 'data' / 'bangumi_tmdb_map.bin'
DEFAULT_OUT_MANIFEST = ROOT / 'assets' / 'data' / 'bangumi_tmdb_manifest.json'

BINARY_MAGIC = b'KTBM'
FORMAT_VERSION_V1 = 1
FORMAT_VERSION_V2 = 2
RECORD_SIZE_V1 = 12
RECORD_SIZE_V2 = 16
FLAG_WIKIDATA = 1 << 0
FLAG_OPEN_ANI = 1 << 1
FLAG_ANIME_LISTS_TVDB = 1 << 2
MOVIE_BIT = 0x80000000
MAX_TMDB_ID = 0x7FFFFFFF
ANIME_LISTS_URL = (
    'https://raw.githubusercontent.com/Fribb/anime-lists/master/anime-list-full.json'
)

TEMPLATE = '''// 由 tool/import_bangumi_tmdb_map.py 自动生成，请勿手动修改映射表。
// 数据来源：Wikidata（P5732 Bangumi 条目 ID ↔ P4983 TMDB 剧集 ID / P4947 TMDB 电影 ID）。
// 许可协议：CC0-1.0（详见 assets/licenses/wikidata-cc0.txt）。
// 快照 SHA-256：__SHA__
// 共 __COUNT__ 个 Bangumi 条目；仅作为跨源打分加权与锚定依据，不直接决定绑定结果。
import '../models/work.dart';

/// Bangumi 条目 ID 到 TMDB 剧集/电影 ID 的离线映射查表（来自 Wikidata 公有领域数据）。
abstract final class BangumiTmdbMap {
  /// 静态内置 Wikidata 映射覆盖的独立 Bangumi 条目数量。
  static int get count => _index.length;

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


def generate_wikidata_dart(source: Path, destination: Path) -> int:
    data = source.read_bytes()
    if len(data) > 8 * 1024 * 1024:
        raise ValueError('映射快照超过 8 MiB，拒绝转换')
    mapping: dict[int, set[str]] = {}
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
    text = (
        TEMPLATE.replace('__SHA__', hashlib.sha256(data).hexdigest())
        .replace('__COUNT__', str(len(entries)))
        .replace('__BODY__', body)
    )
    destination.write_text(text, encoding='utf-8', newline='\n')
    return len(entries)


def load_wikidata_entries(dart_path: Path) -> dict[int, list[tuple[str, int]]]:
    if not dart_path.is_file():
        return {}
    text = dart_path.read_text(encoding='utf-8')
    result: dict[int, list[tuple[str, int]]] = {}
    for match in re.finditer(r"^\s+(\d+):\s+'([^']+)',", text, re.MULTILINE):
        bgm_id = int(match.group(1))
        targets: list[tuple[str, int]] = []
        for token in match.group(2).split(','):
            token = token.strip()
            if len(token) < 2 or not token[1:].isdigit():
                continue
            media_type = 'movie' if token.startswith('m') else 'tv'
            targets.append((media_type, int(token[1:])))
        if targets:
            result[bgm_id] = targets
    return result


def fetch_latest_open_ani() -> tuple[bytes, dict]:
    headers = {
        'User-Agent': 'Konata-Mapping-Builder/1.0',
        'Accept': 'application/vnd.github+json',
    }
    req = urllib.request.Request(
        'https://api.github.com/repos/open-ani/bangumi-tmdb/releases/latest',
        headers=headers,
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        release = json.loads(resp.read().decode('utf-8'))
    assets = {a['name']: a['browser_download_url'] for a in release.get('assets', [])}
    if 'manifest.json' not in assets or 'subjects.json' not in assets:
        raise RuntimeError('上游 open-ani/bangumi-tmdb Release 缺少 manifest.json 或 subjects.json')

    def download(url: str) -> bytes:
        r = urllib.request.Request(url, headers={'User-Agent': 'Konata-Mapping-Builder/1.0'})
        with urllib.request.urlopen(r, timeout=60) as f:
            return f.read()

    manifest_bytes = download(assets['manifest.json'])
    manifest = json.loads(manifest_bytes.decode('utf-8'))
    subjects_bytes = download(assets['subjects.json'])
    expected_sha = (manifest.get('files', {}).get('subjects.json') or {}).get('sha256')
    actual_sha = hashlib.sha256(subjects_bytes).hexdigest()
    if expected_sha and actual_sha != expected_sha:
        raise ValueError(f'subjects.json SHA-256 校验失败: {actual_sha} != {expected_sha}')
    return subjects_bytes, manifest


def fetch_anime_lists_tvdb() -> tuple[dict[int, int], dict[int, int]]:
    """拉取 Fribb/anime-lists（MIT）提取 TheTVDB 剧集 ID 辅助映射（按 TMDB TV ID 与 Bangumi ID 双索引）。"""
    req = urllib.request.Request(
        ANIME_LISTS_URL,
        headers={'User-Agent': 'Konata-Mapping-Builder/1.0'},
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        raw = json.loads(resp.read().decode('utf-8'))
    return parse_anime_lists_tvdb(raw)


def parse_anime_lists_tvdb(items: object) -> tuple[dict[int, int], dict[int, int]]:
    tvdb_by_tmdb: dict[int, int] = {}
    tvdb_by_bgm: dict[int, int] = {}
    if not isinstance(items, list):
        return tvdb_by_tmdb, tvdb_by_bgm
    for item in items:
        if not isinstance(item, dict):
            continue
        raw_tvdb = item.get('thetvdb_id')
        if not isinstance(raw_tvdb, int) or raw_tvdb <= 0:
            continue
        raw_tmdb = item.get('themoviedb_id')
        if isinstance(raw_tmdb, int) and raw_tmdb > 0 and raw_tmdb not in tvdb_by_tmdb:
            tvdb_by_tmdb[raw_tmdb] = raw_tvdb
        raw_bgm = item.get('bangumi_id')
        if isinstance(raw_bgm, int) and raw_bgm > 0 and raw_bgm not in tvdb_by_bgm:
            tvdb_by_bgm[raw_bgm] = raw_tvdb
    return tvdb_by_tmdb, tvdb_by_bgm


def parse_snapshot_date(manifest: dict | None) -> int:
    if manifest:
        for raw in (manifest.get('generatedAt'), (manifest.get('archive') or {}).get('name')):
            if isinstance(raw, str):
                m = re.search(r'(20\d{2})-(\d{2})-(\d{2})', raw)
                if m:
                    return int(f'{m.group(1)}{m.group(2)}{m.group(3)}')
    now = datetime.datetime.now(datetime.timezone.utc)
    return int(now.strftime('%Y%m%d'))


def build_compact_binary(
    *,
    subjects_bytes: bytes,
    upstream_manifest: dict | None,
    wikidata_dart: Path,
    out_bin: Path,
    out_manifest: Path,
    out_bin_v2: Path | None = None,
    out_manifest_v2: Path | None = None,
    tvdb_by_tmdb: dict[int, int] | None = None,
    tvdb_by_bgm: dict[int, int] | None = None,
) -> dict:
    doc = json.loads(subjects_bytes.decode('utf-8'))
    subjects = doc.get('subjects', [])
    if not isinstance(subjects, list):
        raise ValueError('subjects.json 格式异常：缺少 subjects 数组')

    # 按 (bangumiId, mediaType, tmdbId) 聚合，保留最优主季号（优先正片季 > 0，避免单集特典 season=0 覆写主季）。
    merged: dict[tuple[int, str, int], tuple[int, int]] = {}

    for item in subjects:
        if not isinstance(item, dict):
            continue
        bgm_raw = item.get('bangumiId')
        if not isinstance(bgm_raw, int) or bgm_raw <= 0:
            continue
        targets = item.get('targets')
        if not isinstance(targets, list):
            continue
        for target in targets:
            if not isinstance(target, dict):
                continue
            media_type = target.get('type')
            tmdb_raw = target.get('id')
            if media_type not in ('tv', 'movie'):
                continue
            if not isinstance(tmdb_raw, int) or tmdb_raw <= 0 or tmdb_raw > MAX_TMDB_ID:
                continue
            season_raw = target.get('season')
            season = season_raw if isinstance(season_raw, int) and 0 <= season_raw <= 32767 else -1
            key = (bgm_raw, media_type, tmdb_raw)
            prev = merged.get(key)
            if prev is None:
                merged[key] = (season, FLAG_OPEN_ANI)
            else:
                prev_season, prev_flags = prev
                next_season = prev_season
                if season >= 0 and (prev_season < 0 or (prev_season == 0 and season > 0)):
                    next_season = season
                merged[key] = (next_season, prev_flags | FLAG_OPEN_ANI)

    # 合并本地 Wikidata CC0 条目：保留公有领域锚定记录并补充上游尚未覆盖的条目。
    wikidata_entries = load_wikidata_entries(wikidata_dart)
    for bgm_id, wd_targets in wikidata_entries.items():
        for media_type, tmdb_id in wd_targets:
            if tmdb_id <= 0 or tmdb_id > MAX_TMDB_ID:
                continue
            key = (bgm_id, media_type, tmdb_id)
            prev = merged.get(key)
            if prev is None:
                merged[key] = (-1, FLAG_WIKIDATA)
            else:
                merged[key] = (prev[0], prev[1] | FLAG_WIKIDATA)

    ordered_keys = sorted(
        merged.keys(),
        key=lambda k: (k[0], 1 if k[1] == 'movie' else 0, k[2]),
    )
    unique_bgm_count = len({k[0] for k in ordered_keys})
    snapshot_date = parse_snapshot_date(upstream_manifest)
    date_str = f'{snapshot_date // 10000:04d}-{(snapshot_date % 10000) // 100:02d}-{snapshot_date % 100:02d}'

    def write_variant(
        *,
        version: int,
        rec_size: int,
        target_bin: Path,
        target_manifest: Path,
    ) -> dict:
        buf = bytearray()
        buf += struct.pack(
            '<4sHHIIII',
            BINARY_MAGIC,
            version,
            rec_size,
            len(ordered_keys),
            unique_bgm_count,
            snapshot_date,
            0,
        )
        tvdb_hits = 0
        for bgm_id, media_type, tmdb_id in ordered_keys:
            season, flags = merged[(bgm_id, media_type, tmdb_id)]
            packed = (MOVIE_BIT if media_type == 'movie' else 0) | (tmdb_id & MAX_TMDB_ID)
            if version == FORMAT_VERSION_V2:
                tvdb_id = 0
                if media_type == 'tv':
                    if tvdb_by_tmdb and tmdb_id in tvdb_by_tmdb:
                        tvdb_id = tvdb_by_tmdb[tmdb_id]
                    elif tvdb_by_bgm and bgm_id in tvdb_by_bgm:
                        tvdb_id = tvdb_by_bgm[bgm_id]
                if tvdb_id > 0:
                    tvdb_hits += 1
                    flags |= FLAG_ANIME_LISTS_TVDB
                buf += struct.pack('<IIhHI', bgm_id, packed, season, flags, tvdb_id)
            else:
                buf += struct.pack('<IIhH', bgm_id, packed, season, flags)

        bin_bytes = bytes(buf)
        bin_sha256 = hashlib.sha256(bin_bytes).hexdigest()
        target_bin.parent.mkdir(parents=True, exist_ok=True)
        target_bin.write_bytes(bin_bytes)

        upstream_desc = 'open-ani/bangumi-tmdb (CC BY 4.0) + Wikidata (CC0 1.0)'
        if version == FORMAT_VERSION_V2 and tvdb_hits > 0:
            upstream_desc += ' + Fribb/anime-lists (MIT)'
        manifest_payload = {
            'schemaVersion': version,
            'snapshotDate': date_str,
            'snapshotDateInt': snapshot_date,
            'uniqueBangumiCount': unique_bgm_count,
            'recordCount': len(ordered_keys),
            'binBytes': len(bin_bytes),
            'binSha256': bin_sha256,
            'upstreamSource': upstream_desc,
            'upstreamCommit': (upstream_manifest or {}).get('sourceCommit', ''),
            'generatedAt': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
        }
        if version == FORMAT_VERSION_V2:
            manifest_payload['tvdbLinkedCount'] = tvdb_hits
        target_manifest.parent.mkdir(parents=True, exist_ok=True)
        target_manifest.write_text(
            json.dumps(manifest_payload, ensure_ascii=False, indent=2) + '\n',
            encoding='utf-8',
            newline='\n',
        )
        return manifest_payload

    v1_info = write_variant(
        version=FORMAT_VERSION_V1,
        rec_size=RECORD_SIZE_V1,
        target_bin=out_bin,
        target_manifest=out_manifest,
    )
    if out_bin_v2 is not None and out_manifest_v2 is not None:
        v2_info = write_variant(
            version=FORMAT_VERSION_V2,
            rec_size=RECORD_SIZE_V2,
            target_bin=out_bin_v2,
            target_manifest=out_manifest_v2,
        )
        v1_info['v2'] = v2_info
    return v1_info


def main() -> int:
    sys.stdout.reconfigure(encoding='utf-8')
    parser = argparse.ArgumentParser(description='编译 Bangumi ↔ TMDB 离线映射表')
    parser.add_argument('csv_path', nargs='?', help='传统模式：Wikidata CSV 快照路径')
    parser.add_argument('--build-binary', action='store_true', help='生成紧凑二进制表与 manifest.json')
    parser.add_argument('--open-ani', type=Path, help='本地 open-ani/bangumi-tmdb subjects.json 路径')
    parser.add_argument('--open-ani-manifest', type=Path, help='本地 open-ani/bangumi-tmdb manifest.json 路径')
    parser.add_argument('--fetch-open-ani', action='store_true', help='在线拉取 open-ani/bangumi-tmdb 最新 Release')
    parser.add_argument('--fetch-anime-lists', action='store_true', help='在线拉取 Fribb/anime-lists 回填 TheTVDB ID')
    parser.add_argument('--anime-lists', type=Path, help='本地 anime-list-full.json 路径')
    parser.add_argument('--wikidata-dart', type=Path, default=WIKIDATA_DART, help='内置 Wikidata Dart 映射路径')
    parser.add_argument('--out-bin', type=Path, default=DEFAULT_OUT_BIN, help='输出 v1 二进制表路径')
    parser.add_argument('--out-manifest', type=Path, default=DEFAULT_OUT_MANIFEST, help='输出 v1 manifest.json 路径')
    parser.add_argument('--out-bin-v2', type=Path, help='可选同步输出含 tvdb_id 的 v2 二进制表路径')
    parser.add_argument('--out-manifest-v2', type=Path, help='可选同步输出 v2 manifest_v2.json 路径')
    args = parser.parse_args()

    if args.build_binary:
        if args.fetch_open_ani:
            subjects_bytes, upstream_manifest = fetch_latest_open_ani()
        elif args.open_ani:
            subjects_bytes = args.open_ani.read_bytes()
            upstream_manifest = (
                json.loads(args.open_ani_manifest.read_text(encoding='utf-8'))
                if args.open_ani_manifest and args.open_ani_manifest.is_file()
                else None
            )
        else:
            parser.error('--build-binary 需要指定 --open-ani 或 --fetch-open-ani')
        tvdb_by_tmdb: dict[int, int] = {}
        tvdb_by_bgm: dict[int, int] = {}
        if args.fetch_anime_lists:
            tvdb_by_tmdb, tvdb_by_bgm = fetch_anime_lists_tvdb()
        elif args.anime_lists and args.anime_lists.is_file():
            tvdb_by_tmdb, tvdb_by_bgm = parse_anime_lists_tvdb(
                json.loads(args.anime_lists.read_text(encoding='utf-8'))
            )
        info = build_compact_binary(
            subjects_bytes=subjects_bytes,
            upstream_manifest=upstream_manifest,
            wikidata_dart=args.wikidata_dart,
            out_bin=args.out_bin,
            out_manifest=args.out_manifest,
            out_bin_v2=args.out_bin_v2,
            out_manifest_v2=args.out_manifest_v2,
            tvdb_by_tmdb=tvdb_by_tmdb,
            tvdb_by_bgm=tvdb_by_bgm,
        )
        print(
            f"已生成 {args.out_bin.name}：{info['uniqueBangumiCount']} 部动画 / "
            f"{info['recordCount']} 条目标（{info['binBytes']} 字节，SHA-256={info['binSha256'][:12]}）"
        )
        if 'v2' in info and args.out_bin_v2:
            v2 = info['v2']
            print(
                f"已生成 {args.out_bin_v2.name}：{v2['recordCount']} 条目标 / "
                f"{v2.get('tvdbLinkedCount', 0)} 条含 TVDB（{v2['binBytes']} 字节，SHA-256={v2['binSha256'][:12]}）"
            )
        return 0

    if not args.csv_path:
        print(__doc__)
        return 64
    count = generate_wikidata_dart(Path(args.csv_path), WIKIDATA_DART)
    print(f'已生成 {WIKIDATA_DART.name}：{count} 个 Bangumi 条目')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
