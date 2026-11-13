"""Build private, deterministic naming fixtures. No network or media access."""
import argparse
import collections
import hashlib
import json
import pathlib
import re

MARKER = re.compile(r'\{\s*tmdb(?:tv|movie|id)?\s*[-=:]\s*\d+\s*\}|\[\s*tmdb(?:tv|movie|id)?\s*[-=:]\s*\d+\s*\]', re.I)
FOCUS = {
    '七美德': 'native_no_id', '八月的灰姑娘棒球队': 'native_no_id',
    '多罗罗': 'remake_without_year', '16bit的感动': 'multilingual',
    '180秒': 'release_group_vs_title', '9-nine-': 'release_group_vs_title',
    '暗夜第六感 2041': 'numeric_title_year', '2.5次元': 'decimal_title',
    '22／7': 'numeric_title', 'AI电子基因': 'revision',
    '86 -不存在': 'fractional_special', '亚人 第2部分': 'continuous_part',
    '苍穹之法芙娜 EXODUS 第2部分': 'part_and_versions',
    '你好 世界': 'multiple_works', '人生 (2014)': 'directory_file_conflict',
    '猫咪日常': 'multi_episode_file', '银魂 (2006)': 'release_subfolders',
    '福星小子 (1981)': 'multi_episode_and_box',
    '藤丸立香想不明白': 'generic_menu', '空之境界 (2007)': 'nested_collection',
}

def stripped(value):
    return '/'.join(re.sub(r'\s+', ' ', MARKER.sub('', p)).strip() for p in value.split('/'))

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('inventory', type=pathlib.Path)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    args = parser.parse_args()
    raw = args.inventory.read_bytes()
    rows = json.loads(raw.decode('utf-8-sig'))
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    fixtures, groups = [], collections.defaultdict(list)
    for number, row in enumerate(rows, 1):
        assert all(isinstance(row.get(k), str) for k in ('root', 'path', 'name'))
        original = row['path'].strip('/')
        parts = original.split('/')
        marked = [i for i, part in enumerate(parts) if MARKER.search(part)]
        # Sampling boundary only; never an engine input or an identity label.
        boundary = '/'.join(parts[:marked[-1] + 1]) if marked else original
        key = stripped(boundary)
        groups[key].append(number)
        focus = sorted({v for k, v in FOCUS.items() if k in original})
        native = not MARKER.search(original + '/' + row['name'])
        split = 'development' if focus else ('holdout' if int(hashlib.sha256(key.encode()).hexdigest()[:8], 16) % 5 == 0 else 'development')
        fixtures.append({
            'case_id': f'row-{number:06}', 'source_row': number,
            'cohort': 'native_no_id' if native else 'id_removed',
            'split': split, 'focus': focus,
            'input': {k: stripped(row[k]) for k in ('root', 'path', 'name')},
            'annotation': {'identity': 'unverified', 'episode_mapping': 'unverified'},
        })
    assert all(not MARKER.search(json.dumps(f['input'], ensure_ascii=False)) for f in fixtures)
    summary = {
        'source': str(args.inventory.resolve()), 'source_sha256': hashlib.sha256(raw).hexdigest(),
        'records': len(rows), 'cohorts': dict(collections.Counter(f['cohort'] for f in fixtures)),
        'splits': dict(collections.Counter(f['split'] for f in fixtures)),
        'extensions': dict(collections.Counter(pathlib.PurePosixPath(r['name']).suffix.lower() for r in rows)),
        'focus_records': sum(bool(f['focus']) for f in fixtures),
        'sampling_groups': len(groups), 'network_requests': 0, 'media_reads': 0,
        'limitations': ['Video filenames only; no subtitles/audio/scans.',
            'Sampling groups are not verified work identities.',
            'All identity and episode labels remain unverified.',
            'Holdout is a provisional directory-group split, not a franchise-disjoint accuracy benchmark.',
            'Historical IDs are not supplied to the replay or treated as truth.'],
    }
    for name, data in [('manifest.json', summary), ('cases.json', fixtures),
                       ('focus-cases.json', [f for f in fixtures if f['focus']])]:
        (output / name).write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(summary, ensure_ascii=False, indent=2))

if __name__ == '__main__':
    main()
