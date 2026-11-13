"""Compare a small explicitly reviewed naming contract, not remote identity truth."""
import argparse
import json
import pathlib

CONTRACTS = [
    ('row-000042', 'episode', 1, 'The episode token is [01], not title prefix 180.'),
    ('row-016909', 'filename_work.year', None, '2041 is part of NIGHT HEAD 2041; no release year is declared in the filename.'),
    ('row-016909', 'folder_year', 2021, 'Explicit directory year remains 2021.'),
    ('row-069662', 'filename_work.title', 'Soukyuu no Fafner Exodus', 'The leading compound bracket is a release group; compare normalized search text.'),
    ('row-066903', 'filename_work.title', 'Urusei Yatsura', '001&002 belongs to numbering, not the work title.'),
    ('row-075570', 'filename_work.title', 'Gintama', '001-002 belongs to numbering, not the work title.'),
    ('row-000159', 'episode', 1, '22/7 is the title and 01 is the episode.'),
    ('row-002323', 'filename_work.title', 'Nanatsu no Bitoku', 'Native no-ID filename title.'),
    ('row-004029', 'filename_work.title', 'Break Blade', 'Retain file evidence despite conflicting directory name; no provider binding asserted.'),
    ('row-004588', 'filename_work.title', 'ANOTHER WORLD', 'Retain independent title evidence inside HELLO WORLD collection.'),
]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=pathlib.Path)
    args = parser.parse_args()
    root = args.directory
    manifest = json.loads((root / 'manifest.json').read_text(encoding='utf-8'))
    if manifest['source_sha256'] != '7f96032ea38d6871a39dd5cc1e1cfcd321288f6367647b441f50387f93140261':
        raise ValueError('Review source-row annotations for the changed inventory first')
    observations = json.loads((root / 'observations.json').read_text(encoding='utf-8'))
    by_id = {r['case_id']: r for r in observations['observations']}
    results = []
    for case, field, expected, reason in CONTRACTS:
        actual = by_id[case]
        for part in field.split('.'):
            actual = actual[part]
        results.append({'case_id': case, 'field': field, 'expected': expected,
                        'actual': actual, 'matches_contract': actual == expected,
                        'basis': 'reviewed filename syntax, not media content or online identity',
                        'reason': reason})
    result = {'checks': len(results), 'matches': sum(r['matches_contract'] for r in results),
              'differences': sum(not r['matches_contract'] for r in results), 'results': results}
    (root / 'reviewed-contracts.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(result, ensure_ascii=False, indent=2))

if __name__ == '__main__':
    main()
