#!/usr/bin/env python3
"""Read the supported install modes without executing candidate Shell code."""
import argparse
import json
import re
from pathlib import Path

CASE_RE = re.compile(r'^case\s+"\$MODE"\s+in\s*\n(.*?)^esac\s*$', re.MULTILINE | re.DOTALL)
LABEL_RE = re.compile(r'^\s*([a-z0-9_]+(?:\s*\|\s*[a-z0-9_]+)*)\)\s*(?:;;)?\s*$')
MODE_RE = re.compile(r'[a-z0-9_]+')


def labels(block):
    result = []
    for line in block.splitlines():
        match = LABEL_RE.match(line)
        if not match:
            continue
        for mode in re.split(r'\s*\|\s*', match.group(1)):
            if not MODE_RE.fullmatch(mode) or mode in result:
                raise ValueError('duplicate or invalid install mode')
            result.append(mode)
    return result


def parse(text):
    blocks = CASE_RE.findall(text)
    if len(blocks) != 2:
        raise ValueError('expected exactly the validation and dispatch MODE cases')
    accepted, dispatched = (labels(block) for block in blocks)
    if not accepted or set(accepted) != set(dispatched):
        raise ValueError('accepted and dispatched install modes differ')
    return accepted


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('test_install', type=Path)
    args = parser.parse_args()
    print(json.dumps(parse(args.test_install.read_text()), separators=(',', ':')))


if __name__ == '__main__':
    main()
