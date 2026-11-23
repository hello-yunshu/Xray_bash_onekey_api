#!/usr/bin/env python3
"""Validate and match narrowly scoped, reviewed compatibility exceptions."""
import argparse
import copy
import json
import re
from pathlib import Path

ALLOWED_SCENARIOS = frozenset(('fresh', 'legacy-upgrade', 'reinstall', 'fallback'))
DIAGNOSTICS = frozenset(('permission denied observed',))
TUPLE_PATTERNS = {'xrayVersion': r'[0-9]+\.[0-9]+\.[0-9]+',
                  'installerRef': r'[0-9a-f]{40}',
                  'installerSha256': r'[0-9a-f]{64}'}


def validate_candidate(candidate):
    if (not isinstance(candidate, dict) or set(candidate) != set(TUPLE_PATTERNS) or
            any(not isinstance(candidate.get(field), str) or not re.fullmatch(pattern, candidate[field])
                for field, pattern in TUPLE_PATTERNS.items())):
        raise ValueError('invalid exception candidate tuple')


def validate(doc):
    entries = doc.get('expectedIncompatible', [])
    if not isinstance(entries, list):
        raise ValueError('expectedIncompatible must be a list')
    baselines = doc.get('baselines', [])
    known = {item.get('version') for item in baselines if isinstance(item, dict)}
    seen = set()
    for entry in entries:
        if (not isinstance(entry, dict) or
                set(entry) != {'baseline', 'scenarios', 'candidate', 'diagnostic', 'reason'}):
            raise ValueError('invalid expected-incompatible declaration')
        baseline = entry['baseline']
        scenarios = entry['scenarios']
        if not isinstance(baseline, str) or baseline not in known:
            raise ValueError('unknown expected-incompatible baseline')
        if (not isinstance(scenarios, list) or not scenarios or
                any(not isinstance(item, str) or item not in ALLOWED_SCENARIOS for item in scenarios) or
                len(set(scenarios)) != len(scenarios)):
            raise ValueError('invalid or non-waivable expected-incompatible scenario')
        validate_candidate(entry['candidate'])
        if entry['diagnostic'] not in DIAGNOSTICS:
            raise ValueError('unknown expected-incompatible diagnostic')
        if not isinstance(entry['reason'], str) or not entry['reason'].strip() or len(entry['reason']) > 500:
            raise ValueError('invalid expected-incompatible reason')
        identity = json.dumps(entry['candidate'], sort_keys=True)
        for scenario in scenarios:
            key = (baseline, scenario, identity)
            if key in seen:
                raise ValueError('duplicate expected-incompatible declaration')
            seen.add(key)
    return entries


def expected(doc, baseline, scenario, candidate):
    validate_candidate(candidate)
    matches = [entry for entry in validate(doc)
               if entry['baseline'] == baseline and scenario in entry['scenarios'] and
               entry['candidate'] == candidate]
    if len(matches) > 1:
        raise ValueError('ambiguous expected-incompatible declaration')
    return copy.deepcopy(matches[0]) if matches else None


def any_for_baseline(doc, baseline, candidate):
    validate_candidate(candidate)
    return any(entry['baseline'] == baseline and entry['candidate'] == candidate for entry in validate(doc))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    check = sub.add_parser('validate')
    check.add_argument('config', type=Path)
    for command in ('match', 'matches-baseline'):
        match = sub.add_parser(command)
        match.add_argument('config', type=Path)
        match.add_argument('--baseline', required=True)
        match.add_argument('--scenario')
        match.add_argument('--candidate', type=Path, required=True)
    args = parser.parse_args()
    doc = json.loads(args.config.read_text())
    if args.command == 'validate':
        validate(doc)
        return
    candidate = json.loads(args.candidate.read_text())
    if args.command == 'matches-baseline':
        if args.scenario:
            parser.error('matches-baseline does not take --scenario')
        print('true' if any_for_baseline(doc, args.baseline, candidate) else 'false')
        return
    if not args.scenario:
        parser.error('match requires --scenario')
    print(json.dumps(expected(doc, args.baseline, args.scenario, candidate), sort_keys=True))


if __name__ == '__main__':
    main()
