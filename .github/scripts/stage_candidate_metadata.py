#!/usr/bin/env python3
"""Stage a paired candidate after comparing the current API tuple to its baseline.

This prepares bytes only; qualification, publication and Git concurrency checks
are the caller's responsibility. It never modifies the input metadata file.
"""
import argparse
import json
import re
from pathlib import Path

FIELDS = ('xray_online_version', 'xray_installer_ref', 'xray_installer_sha256')


def version(value):
    if not isinstance(value, str) or not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', value):
        raise ValueError('invalid Xray version')
    return tuple(map(int, value.split('.')))


def stage(current, expected, candidate):
    if not all(isinstance(v, dict) for v in (current, expected, candidate)):
        raise ValueError('metadata must be JSON objects')
    for obj in (current, expected, candidate):
        version(obj.get(FIELDS[0]))
        for key, regex in ((FIELDS[1], r'[0-9a-f]{40}'), (FIELDS[2], r'[0-9a-f]{64}')):
            if not isinstance(obj.get(key), str) or not re.fullmatch(regex, obj[key]):
                raise ValueError('invalid installer identity')
    if any(current[key] != expected[key] for key in FIELDS):
        raise ValueError('online candidate baseline changed')
    if version(candidate[FIELDS[0]]) < version(current[FIELDS[0]]):
        raise ValueError('automatic downgrade refused')
    result = dict(current)
    result.update({key: candidate[key] for key in FIELDS})
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('current', 'expected', 'candidate', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    documents = [json.loads(path.read_text()) for path in (args.current, args.expected, args.candidate)]
    result = stage(*documents)
    with args.output.open('x') as f:
        json.dump(result, f, ensure_ascii=False, indent=2)
        f.write('\n')


if __name__ == '__main__':
    main()
