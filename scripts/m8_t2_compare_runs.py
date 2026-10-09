#!/usr/bin/env python3
"""Summarize exact pass/fail changes between two sanitized M8-T2 reports."""
import argparse
import collections
import json


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline")
    parser.add_argument("candidate")
    args = parser.parse_args()
    before = json.load(open(args.baseline))
    after = json.load(open(args.candidate))
    if (before['seed'], before['scenario']) != (after['seed'], after['scenario']):
        raise SystemExit('seed/scenario mismatch')
    cases_before = {(c['route'], c['role']): c for c in before['cases']}
    cases_after = {(c['route'], c['role']): c for c in after['cases']}
    if cases_before.keys() != cases_after.keys():
        raise SystemExit('case-key mismatch')
    transition = collections.defaultdict(list)
    for key in sorted(cases_before):
        old, new = cases_before[key], cases_after[key]
        if old['status'] != new['status']:
            transition[(old['status'], new['status'])].append(key)
    for (old, new), keys in sorted(transition.items()):
        print(f'{old} -> {new}: {len(keys)} cells; rows {sorted({route for route, _ in keys})}')
    for label, report in (('baseline', before), ('candidate', after)):
        cases = report['cases']
        counts = collections.Counter(c['status'] for c in cases)
        categories = collections.Counter()
        headers = collections.Counter()
        for case in cases:
            for problem in case.get('problems', []):
                if problem.startswith('headers '):
                    categories['header'] += 1
                    headers[problem.removeprefix('headers ')] += 1
                elif problem.startswith('body '): categories['body'] += 1
                elif problem.startswith('state '): categories['state'] += 1
                elif problem.startswith('status '): categories['http_status'] += 1
                elif problem.startswith('request or snapshot error:'): categories['infrastructure'] += 1
        print(label, dict(counts), 'problem_types', dict(categories))
        for names, amount in headers.most_common():
            print(' ', amount, names)


if __name__ == '__main__':
    main()
