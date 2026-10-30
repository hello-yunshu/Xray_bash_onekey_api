#!/usr/bin/env python3
"""Authenticate a completed qualification before promoting an Xray fallback."""
import argparse
import json
import re
from pathlib import Path

import prepare_api_release
import verify_qualification_run


def verify(evidence_bytes, current, baselines, target, run_id, attempt, commit):
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', target):
        raise ValueError('invalid tested version')
    evidence = json.loads(evidence_bytes)
    base, candidate = evidence.get('base', {}), evidence.get('candidate', {})
    fields = (('xrayVersion', 'xray_online_version'), ('installerRef', 'xray_installer_ref'),
              ('installerSha256', 'xray_installer_sha256'))
    for evidence_field, metadata_field in fields:
        if base.get(evidence_field) != current.get(metadata_field) or candidate.get(evidence_field) != current.get(metadata_field):
            raise ValueError('qualification tuple differs from current metadata')
    if base.get('testedVersion') != current.get('xray_tested_version') or candidate.get('testedVersion') != target:
        raise ValueError('qualification fallback differs from current or requested version')
    for entry in evidence.get('baselines', []):
        if entry.get('scenarios', {}).get('fallback', {}).get('binary', {}).get('version') != target:
            raise ValueError('fallback binary differs from requested version')
    proposed = dict(current, xray_tested_version=target)
    prepare_api_release.prepare(proposed, evidence, baselines)
    verify_qualification_run.verify(evidence_bytes, 'hello-yunshu/Xray_bash_onekey_api', run_id, commit, attempt)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--evidence', type=Path, required=True)
    p.add_argument('--current', type=Path, required=True)
    p.add_argument('--baselines', type=Path, required=True)
    p.add_argument('--target', required=True)
    p.add_argument('--run-id', type=int, required=True)
    p.add_argument('--attempt', type=int, required=True)
    p.add_argument('--commit', required=True)
    a = p.parse_args()
    verify(a.evidence.read_bytes(), json.loads(a.current.read_text()), json.loads(a.baselines.read_text()),
           a.target, a.run_id, a.attempt, a.commit)


if __name__ == '__main__':
    main()
