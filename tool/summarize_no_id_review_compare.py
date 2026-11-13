"""Score only frozen, independently reviewed naming labels; unknown stays unknown."""
import argparse
import collections
import hashlib
import json
from pathlib import Path


def read(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def adopted(row):
    if not row or row.get('state') != 'confirmed' or not row.get('adopted'):
        return None
    return json.loads(row['adopted'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('annotations', type=Path)
    args = parser.parse_args()
    lock = read(args.directory / 'annotation-lock.json')
    assert hashlib.sha256(args.annotations.read_bytes()).hexdigest() == lock['annotation_sha256']
    annotations = {a['review_id']: a for a in read(args.annotations)['annotations']}
    batch = {b['review_id']: b for b in read(args.directory / 'review-batch.json')}
    details, summaries = [], {}
    for mode in ['legacy', 'new']:
        observed = read(args.directory / f'{mode}-results.json')
        assert len(observed) == len(batch) == 24
        counts = collections.Counter()
        for result in observed:
            key = result['review_id']
            inputs = {f['case_id']: f['input'] for f in batch[key]['files']}
            works = {w['id']: w for w in result.get('works', [])}
            assets = {a['relative_path']: a for a in result.get('assets', [])}
            bindings = {(b['provider'], b['layer'], b['scope'] if b['layer'] == 'episode' else b['work_id']): b
                        for b in result.get('bindings', []) if b['layer'] != 'range'}
            for truth in annotations[key]['files']:
                if truth['status'] != 'verified_naming_mapping':
                    counts['unverified_files_excluded'] += 1
                    continue
                inp = inputs[truth['case_id']]
                path = (inp['path'] + '/' + inp['name']).lstrip('/')
                asset = assets.get(path)
                work = works.get(asset['work_id']) if asset else None
                for provider in ['tmdb', 'bangumi']:
                    expected = truth[provider]
                    wanted_id = expected['id' if provider == 'tmdb' else 'subject']
                    got_id = got_type = selected = None
                    if mode == 'legacy' and work and work.get('needs_review') == 0:
                        got_id = work.get(provider + '_id')
                        got_type = work.get('tmdb_type')
                        if provider == 'tmdb' and got_id is not None:
                            selected = {'season': asset.get('season'), 'episode': asset.get('episode')}
                    elif mode == 'new' and asset:
                        identity = adopted(bindings.get((provider, 'work', asset['work_id'])))
                        got_id = identity.get('id') if identity else None
                        got_type = identity.get('type') if identity else None
                        selected = adopted(bindings.get((provider, 'episode', asset['id'])))
                    identity_state = ('not_confirmed' if got_id is None else 'correct'
                                      if got_id == wanted_id and (provider != 'tmdb' or got_type == expected['type']) else 'wrong')
                    if mode == 'legacy' and provider == 'bangumi':
                        chapter_state = 'not_represented_by_legacy'
                    elif selected is None:
                        chapter_state = 'not_confirmed'
                    elif provider == 'tmdb':
                        chapter_state = 'correct' if identity_state == 'correct' and all(
                            selected.get(k) == expected[k] for k in ['season', 'episode']) else 'wrong'
                    else:
                        chapter_state = 'correct' if identity_state == 'correct' and selected.get('id') == expected['episode_id'] and selected.get('sort') == expected['sort'] else 'wrong'
                    counts[f'{provider}.identity.{identity_state}'] += 1
                    counts[f'{provider}.chapter.{chapter_state}'] += 1
                    details.append({'review_id': key, 'case_id': truth['case_id'], 'mode': mode,
                                    'provider': provider, 'identity': identity_state, 'chapter': chapter_state,
                                    'expected': expected, 'observed_id': got_id, 'observed_chapter': selected})
        summaries[mode] = {'completed_cases': len(observed), 'execution_failures': sum(r.get('status') != 'observed' for r in observed),
                           'indexed_assets': sum(len(r.get('assets', [])) for r in observed),
                           'work_records': sum(len(r.get('works', [])) for r in observed),
                           'requests': sum(r['requests'] for r in observed),
                           'http_statuses': dict(sum((collections.Counter(r['statuses']) for r in observed), collections.Counter())),
                           'counts': dict(counts)}
    (args.directory / 'scored-files.json').write_text(json.dumps(details, ensure_ascii=False, indent=2), encoding='utf-8')
    (args.directory / 'comparison-summary.json').write_text(json.dumps(summaries, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(summaries, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
