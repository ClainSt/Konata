"""Read a Konata incident TXT locally. No uploads, dependencies, or file writes."""
import argparse
import json
import re
from pathlib import Path


def analyze(text):
    # The anchor is repeated in the human-readable heading. Count context once.
    context = text.partition('--- context (chronological) ---')[2]
    if not context:
        raise ValueError('Missing Konata incident context marker')
    sessions, requests, issues = {}, {}, []
    legacy = malformed = 0
    for line in context.splitlines():
        match = re.match(r'^(\S+) \[(\w+)\] \[([^]]+)\] (.*)$', line)
        if not match:
            continue
        timestamp, level, module, payload = match.groups()
        try:
            event = json.loads(payload)
        except ValueError:
            legacy += 1
            continue
        if not isinstance(event, dict) or not isinstance(event.get('event'), str):
            malformed += 1
            continue
        if level in ('WARN', 'ERROR'):
            issues.append({'time': timestamp, 'level': level, 'module': module, **event})
        session = event.get('session')
        if module == 'Playback':
            sessions.setdefault(session or 'unscoped', []).append({'time': timestamp, **event})
        request = event.get('request')
        if module == 'WebDAVStream' and request:
            # Last observation wins; unfinished requests remain visible.
            requests.setdefault(request, {}).update(event)
    return {'sessions': sessions, 'requests': requests, 'issues': issues,
            'legacyRecords': legacy, 'malformedRecords': malformed}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('txt', type=Path)
    parser.add_argument('--json', action='store_true')
    args = parser.parse_args()
    if args.txt.stat().st_size > 1024 * 1024:
        parser.error('Expected a bounded incident TXT (at most 1 MiB)')
    result = analyze(args.txt.read_text(encoding='utf-8-sig'))
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return
    print('Partial incident context; absence of errors does not prove smooth playback.')
    for session, events in result['sessions'].items():
        print(f'\nSession {session}')
        for event in events:
            print(f"  {event['time']} {event['event']} "
                  f"elapsedMs={event.get('elapsedMs', '?')} "
                  f"positionMs={event.get('positionMs', '?')}")
    print('\nRequests: headers / first body / maximum observed gap (ms)')
    for request, row in result['requests'].items():
        print(f"  {request} {row.get('purpose')} offset={row.get('rangeStart')} "
              f"{row.get('headersMs')} / {row.get('firstByteMs')} / {row.get('maxObservedGapMs')} "
              f"upstream={row.get('upstreamStatus')} phase={row.get('phase')} "
              f"failure={row.get('failure')} cancelled={row.get('cancelled')} "
              f"last={row.get('event')}")
    print(f"\nRecorded issues={len(result['issues'])}; legacy={result['legacyRecords']}; "
          f"malformed={result['malformedRecords']}")
    print('Inspect TXT header for omitted records, write failures, detail mode and build identity.')


if __name__ == '__main__':
    main()
