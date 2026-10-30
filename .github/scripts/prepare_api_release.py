#!/usr/bin/env python3
"""Prepare deterministic release bytes; this tool never authenticates evidence or publishes."""
import argparse
import hashlib
import json
import re
from pathlib import Path


def sha(data):
    return hashlib.sha256(data).hexdigest()


def json_bytes(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + '\n').encode()


def prepare(metadata, evidence, baselines):
    if evidence.get('schemaVersion') != 1 or baselines.get('schemaVersion') != 1:
        raise ValueError('unsupported schema')
    candidate = evidence.get('candidate', {})
    for key, pattern in (('xrayVersion', r'\d+\.\d+\.\d+'),
                         ('installerRef', r'[0-9a-f]{40}'),
                         ('installerSha256', r'[0-9a-f]{64}')):
        if not isinstance(candidate.get(key), str) or not re.fullmatch(pattern, candidate[key]):
            raise ValueError(f'invalid candidate {key}')
    if (metadata.get('xray_online_version'), metadata.get('xray_installer_ref'),
            metadata.get('xray_installer_sha256')) != (candidate['xrayVersion'], candidate['installerRef'], candidate['installerSha256']):
        raise ValueError('metadata and evidence candidate differ')
    if 'testedVersion' in candidate and metadata.get('xray_tested_version') != candidate['testedVersion']:
        raise ValueError('metadata and evidence fallback differ')
    expected = {b['version']: (b['commit'], b['installSha256']) for b in baselines['baselines']}
    if len(expected) != len(baselines['baselines']) or not expected:
        raise ValueError('invalid baseline list')
    required = {'fresh', 'legacy-upgrade', 'shell-then-upgrade', 'reinstall', 'failure-recovery', 'restart-recovery', 'fallback'}
    entries = evidence.get('baselines')
    if not isinstance(entries, list) or len(entries) != len(expected):
        raise ValueError('missing baseline results')
    seen = set()
    for entry in entries:
        version = entry.get('version')
        if version in seen or version not in expected:
            raise ValueError('unknown or duplicate baseline')
        seen.add(version)
        if (entry.get('commit'), entry.get('installSha256')) != expected[version]:
            raise ValueError('baseline identity mismatch')
        configured = next(b for b in baselines['baselines'] if b['version'] == version)
        if 'initial' in configured and entry.get('initial') != configured['initial']:
            raise ValueError('initial baseline tuple mismatch')
        scenarios = entry.get('scenarios')
        if not isinstance(scenarios, dict) or set(scenarios) != required:
            raise ValueError('missing required scenario')
        for result in scenarios.values():
            if not isinstance(result, dict) or result.get('conclusion') != 'success':
                raise ValueError('scenario not successful')
            if not isinstance(result.get('runId'), int) or isinstance(result['runId'], bool) or result['runId'] <= 0:
                raise ValueError('invalid run identity')
            if not isinstance(result.get('job'), str) or not result['job'].strip():
                raise ValueError('missing job identity')
            if not isinstance(result.get('environment'), dict) or not result['environment']:
                raise ValueError('missing test environment')
    return {'xray_shell_versions.json': json_bytes(metadata), 'compatibility.json': json_bytes(evidence)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--metadata', type=Path, required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--baselines', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    files = prepare(*(json.loads(p.read_text()) for p in (args.metadata, args.evidence, args.baselines)))
    sums = ''.join(f'{sha(data)}  {name}\n' for name, data in sorted(files.items())).encode()
    files['SHA256SUMS'] = sums
    args.output.mkdir(parents=True, exist_ok=True)
    if any(args.output.iterdir()):
        raise ValueError('output directory must be empty')
    for name, data in files.items():
        with (args.output / name).open('xb') as handle:
            handle.write(data)


if __name__ == '__main__':
    main()
