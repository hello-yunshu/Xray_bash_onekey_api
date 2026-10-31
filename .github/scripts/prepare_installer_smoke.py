#!/usr/bin/env python3
"""Prepare a released installer smoke test without its early-closing version reader.

Only the test harness is copied and adjusted; the released installer and Shell
are never modified. Unknown future harness versions are copied unchanged.
"""
import argparse
from pathlib import Path

OLD = "awk '/Xray/{print $2; exit}'"
NEW = "awk '/Xray/ && !seen {print $2; seen=1}'"


def prepare(source, destination):
    original = Path(source).read_text()
    count = original.count(OLD)
    if count > 1:
        raise ValueError('ambiguous version-reader occurrences')
    Path(destination).write_text(original.replace(OLD, NEW))
    return count == 1


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    print('Prepared installer smoke harness; version reader adjusted:', prepare(args.source, args.destination))
