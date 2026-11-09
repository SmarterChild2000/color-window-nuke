#!/usr/bin/env python3
"""Summarise a Color Window Nuke log (JSON lines), newest Illustrator session.

Reports: whether the plug-in started with everything it needs, each Fill/Stroke
proxy click with the windows that appeared and the decision, and every reversal
with its verification. Use --all for every session in the file.
"""
import glob
import json
import os
import sys


def main(argv):
    args = [a for a in argv if not a.startswith('--')]
    path = args[0] if args else max(glob.glob(os.path.expanduser('~/Library/Logs/ColorWindowNuke/*.jsonl')),
                                    key=os.path.getmtime, default=None)
    if not path:
        print('no logs found')
        return 1
    rows = [json.loads(l) for l in open(path) if l.strip()]
    starts = [i for i, r in enumerate(rows) if r['event'] == 'startup']
    if not starts:
        print('no session in', path)
        return 1
    if '--all' not in argv:
        rows = rows[starts[-1]:]
    t0 = rows[0]['t']
    s = rows[0]
    ready = next((r for r in rows if r['event'] == 'ready'), {})
    print('log: %s' % path)
    print('session: build=%s verified=%s plug-in=%s mode=%s paintStyleSuite=%s' % (
        s.get('build'), s.get('buildVerified'), s.get('version'),
        {0: 'off', 1: 'diagnose', 2: 'enforce'}.get(ready.get('mode'), '?'), ready.get('paintStyleSuite')))
    clicks = reversals = ok = 0
    for r in rows:
        e, t = r['event'], r['t'] - t0
        if e == 'fillStrokeChanged':
            clicks += 1
            wins = ', '.join('%s@L%s %s' % (w['cls'], w['level'], w['frame']) for w in r.get('newWindows', [])) or '-'
            act = 'REVERSE' if r.get('decision') else ('would reverse' if r.get('enforceWouldReverse') else 'leave')
            why = r.get('reason') if r.get('decision') or 'enforceReason' not in r else r['enforceReason']
            print('%7.2fs  click g%-3s %-13s %-12s new: %s  (%s)' % (t, r.get('gesture'), r.get('currentEvent'), act, wins, why))
        elif e == 'reversed':
            reversals += 1
            print('%7.2fs    reversed g%s: windowGone=%s latency=%.2f ms' % (t, r.get('gesture'), r.get('windowGone'), r.get('latencyMs', 0)))
        elif e == 'reversalVerified':
            ok += not r.get('windowVisible')
            print('%7.2fs    verified g%s: windowVisible=%s' % (t, r.get('gesture'), r.get('windowVisible')))
        elif e == 'runloopBeforeWaiting':
            print('%7.2fs    commit point after %.2f ms, window visible=%s' % (t, r.get('sinceNotifyMs', 0), r.get('windowVisible')))
        elif e in ('colorCommandBefore', 'colorCommandAfter', 'sessionDisabled', 'reversalSkipped'):
            print('%7.2fs  %s %s' % (t, e, {k: v for k, v in r.items() if k not in ('event', 't', 'wall')}))
    print('\nproxy clicks: %d, reversals: %d, verified closed: %d' % (clicks, reversals, ok))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
