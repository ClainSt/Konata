"""Build a private development review batch; never infer platform truth."""
import argparse
import collections
import hashlib
import json
from pathlib import Path


def read(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--contracts', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    rows = read(args.baseline)
    groups = collections.defaultdict(list)
    for row in rows:
        parts = row['input']['path'].strip('/').split('/')
        # Split this broad collection at its existing series directory, while
        # retaining the original ancestor paths in every engine input.
        depth = 3 if len(parts) > 2 and parts[1] == '型月作品集' else 2
        key = '/'.join(parts[:depth])
        groups[key].append(row)
    native = [k for k, rs in groups.items()
              if all(r['cohort'] == 'native_no_id' for r in rs)]
    selected = []
    for title in ['七美德', '二之国', '八月的灰姑娘棒球队', '多罗罗',
                  '在这世界（更多一些）的角落', '大炮破坏者',
                  '奴隶区 我与23人的奴隶', '富豪刑事 Balance：UNLIMITED']:
        matches = [k for k in native if k.split('/')[-1] == title]
        assert len(matches) == 1, (title, matches)
        selected.append((matches[0], 'native_priority'))
    for key in sorted(native, key=lambda k: hashlib.sha256(
            ('review-batch-v1:' + k).encode()).hexdigest()):
        if key not in {k for k, _ in selected} and len(selected) < 12:
            selected.append((key, 'native_deterministic'))
    for title in ['16bit的感动', '180秒', '暗夜第六感 2041', '2.5次元',
                  '22／7', 'AI电子基因', '9-nine-', '人生 (2014)',
                  '你好 世界', '猫咪日常', '亚人系列', '空之境界系列']:
        matches = [k for k in groups if title in k]
        assert len(matches) == 1, (title, matches)
        selected.append((matches[0], 'risk_priority'))
    assert len(selected) == len({k for k, _ in selected}) == 24
    contracts = read(args.contracts)['results']
    batch = []
    for index, (key, reason) in enumerate(selected, 1):
        members = groups[key]
        ids = {r['case_id'] for r in members}
        syntax = [{k: c[k] for k in ('case_id', 'field', 'expected', 'basis', 'reason')}
                  for c in contracts if c['case_id'] in ids]
        batch.append({
            'review_id': f'review-{index:03}', 'directory_group': key,
            'selection_reason': reason, 'role': 'development_not_blind',
            'cohorts': dict(collections.Counter(r['cohort'] for r in members)),
            'risk_tags': sorted({t for r in members for t in r['focus']}),
            'subdirectories': sorted({r['input']['path'] for r in members}),
            'files': [{'case_id': r['case_id'], 'source_row': r['source_row'],
                       'input': r['input']} for r in members],
            'reviewed_syntax_contracts': syntax,
            'truth': {'identity': 'unverified', 'range': 'unverified',
                      'episode_mapping': 'unverified', 'franchise_group': None,
                      'sources': [], 'reviewer': None},
        })
    all_ids = [f['case_id'] for b in batch for f in b['files']]
    assert len(all_ids) == len(set(all_ids))
    args.output.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(batch, ensure_ascii=False, indent=2) + '\n'
    (args.output / 'review-batch.json').write_text(payload, encoding='utf-8')
    manifest = {
        'version': 1, 'role': 'development_not_blind',
        'baseline_sha256': hashlib.sha256(args.baseline.read_bytes()).hexdigest(),
        'batch_sha256': hashlib.sha256((args.output / 'review-batch.json').read_bytes()).hexdigest(),
        'native_directory_groups_available': len(native),
        'selected_groups': len(batch), 'selected_files': len(all_ids),
        'cohorts': dict(sum((collections.Counter(b['cohorts']) for b in batch), collections.Counter())),
        'syntax_contracts': sum(len(b['reviewed_syntax_contracts']) for b in batch),
        'verified_platform_identities': 0, 'network_requests': 0,
        'limitations': ['Top directory groups are not verified independent works.',
                       'All platform truth remains unverified.',
                       'Development selection is not a blind or random accuracy sample.'],
    }
    (args.output / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf-8')
    lines = ['# 第一批开发核验目录', '',
             '| 编号 | 目录组 | 文件数 | 子目录数 | 选择依据 | 风险标签 |',
             '|---|---|---:|---:|---|---|']
    for b in batch:
        lines.append(f"| {b['review_id']} | {b['directory_group']} | {len(b['files'])} | {len(b['subdirectories'])} | {b['selection_reason']} | {', '.join(b['risk_tags']) or '待人工补标'} |")
    (args.output / 'review-queue.md').write_text('\n'.join(lines) + '\n', encoding='utf-8')
    print(json.dumps(manifest, ensure_ascii=False))


if __name__ == '__main__':
    main()
