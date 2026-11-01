#!/usr/bin/env python3
"""Record a tuple only after the publisher authenticates its full qualification."""
import argparse
import copy
import json
from pathlib import Path

import select_trusted_initials


def record(baselines, metadata):
    initial = {field: metadata[key] for field, key in (
        ('xrayVersion', 'xray_online_version'), ('installerRef', 'xray_installer_ref'),
        ('installerSha256', 'xray_installer_sha256'))}
    select_trusted_initials.trusted({}, {'initial': initial})
    result = copy.deepcopy(baselines)
    pool = result.get('trustedInitials', [])
    result['trustedInitials'] = [initial, *(item for item in pool if item != initial)]
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baselines', type=Path, required=True)
    parser.add_argument('--metadata', type=Path, required=True)
    args = parser.parse_args()
    result = record(json.loads(args.baselines.read_text()), json.loads(args.metadata.read_text()))
    args.baselines.write_text(json.dumps(result, indent=2) + '\n')


if __name__ == '__main__':
    main()
