#!/usr/bin/env python3
"""Collect exact job results; workflow trust and candidate inputs are caller-owned."""
import argparse
import json
import re
from pathlib import Path

SCENARIOS = {'fresh': 'fresh', 'legacy-upgrade': 'direct',
             'shell-then-upgrade': 'shell-first', 'reinstall': 'reinstall',
             'failure-recovery': 'failure-recovery', 'fallback': 'fallback'}
MODES = ('xtls_only', 'ws_grpc_xhttp', 'reality', 'reality_nginx', 'tls')
INSTALLER_SCENARIOS = ('fresh', 'reinstall', 'remove')
BOOTSTRAP_IMAGES = ('debian:12-slim', 'debian:13-slim', 'ubuntu:24.04', 'ubuntu:26.04', 'quay.io/centos/centos:stream10')


def collect(baselines, jobs, candidate, base, facts, run_id, commit, attempt):
    if baselines.get('schemaVersion') != 1 or not baselines.get('baselines'):
        raise ValueError('missing baselines')
    if not re.fullmatch(r'[0-9a-f]{40}', commit) or run_id < 1 or attempt < 1:
        raise ValueError('invalid qualification identity')
    for obj in (candidate, base):
        for field, pattern in (('xrayVersion', r'[0-9]+\.[0-9]+\.[0-9]+'),
                               ('installerRef', r'[0-9a-f]{40}'), ('installerSha256', r'[0-9a-f]{64}')):
            if not isinstance(obj.get(field), str) or not re.fullmatch(pattern, obj[field]):
                raise ValueError('invalid candidate or base')
    entries = []
    versions = set()
    observed = {}
    for baseline in baselines['baselines']:
        version = baseline['version']
        if version in versions or not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version):
            raise ValueError('invalid or duplicate baseline')
        versions.add(version)
        if not re.fullmatch(r'[0-9a-f]{40}', baseline['commit']) or not re.fullmatch(r'[0-9a-f]{64}', baseline['installSha256']):
            raise ValueError('invalid baseline identity')
        initial = baseline.get('initial', {k: base[k] for k in ('xrayVersion', 'installerRef', 'installerSha256')})
        for field, pattern in (('xrayVersion', r'[0-9]+\.[0-9]+\.[0-9]+'),
                               ('installerRef', r'[0-9a-f]{40}'), ('installerSha256', r'[0-9a-f]{64}')):
            if not isinstance(initial.get(field), str) or not re.fullmatch(pattern, initial[field]):
                raise ValueError('invalid initial baseline tuple')
        scenarios = {}
        for key, scenario in SCENARIOS.items():
            name = f'qualify / Legacy upgrade ({version}, {scenario})'
            matching = [job for job in jobs if job.get('name') == name]
            if len(matching) != 1 or matching[0].get('status') != 'completed' or matching[0].get('conclusion') != 'success':
                raise ValueError(f'missing or unsuccessful job: {name}')
            job_id = matching[0].get('id')
            if not isinstance(job_id, int) or isinstance(job_id, bool) or job_id < 1:
                raise ValueError(f'invalid job identity: {name}')
            fact_key = f'{version}-{scenario}'
            fact = facts.get(fact_key, {})
            expected_version = (base.get('testedVersion') if key == 'fallback' else
                                initial['xrayVersion'] if key == 'failure-recovery' else candidate['xrayVersion'])
            if (fact.get('version') != expected_version or
                    not re.fullmatch(r'[0-9a-f]{64}', str(fact.get('sha256', ''))) or
                    fact.get('arch') not in ('x86_64', 'aarch64')):
                raise ValueError(f'missing or invalid binary evidence: {fact_key}')
            identity = (fact['version'], fact['arch'])
            if identity in observed and observed[identity] != fact['sha256']:
                raise ValueError(f'inconsistent binary bytes: {fact_key}')
            observed[identity] = fact['sha256']
            coverage = 'production-entry'
            if key == 'fallback':
                coverage = 'direct-fallback-function'
            elif key == 'legacy-upgrade' and initial['xrayVersion'] == candidate['xrayVersion']:
                coverage = 'same-version-reinstall'
            scenarios[key] = {'conclusion': 'success', 'runId': run_id, 'jobId': job_id, 'job': name,
                              'binary': fact,
                              'environment': {'runner': 'ubuntu-latest', 'mode': 'reality',
                                              'coverage': coverage}}
        entries.append({'version': version, 'commit': baseline['commit'],
                        'installSha256': baseline['installSha256'], 'initial': initial, 'scenarios': scenarios})
    modes = []
    for mode in MODES:
        name = f'Full install ({mode})'
        found = [job for job in jobs if job.get('name') == name]
        if len(found) != 1 or found[0].get('status') != 'completed' or found[0].get('conclusion') != 'success':
            raise ValueError(f'missing or unsuccessful job: {name}')
        job_id = found[0].get('id')
        if not isinstance(job_id, int) or isinstance(job_id, bool) or job_id < 1:
            raise ValueError(f'invalid job identity: {name}')
        modes.append({'mode': mode, 'runId': run_id, 'jobId': job_id, 'job': name})
    installer_jobs = []
    for scenario in INSTALLER_SCENARIOS:
        name = f'Installer smoke ({scenario})'
        found = [job for job in jobs if job.get('name') == name]
        if len(found) != 1 or found[0].get('status') != 'completed' or found[0].get('conclusion') != 'success':
            raise ValueError(f'missing or unsuccessful job: {name}')
        job_id = found[0].get('id')
        if not isinstance(job_id, int) or isinstance(job_id, bool) or job_id < 1:
            raise ValueError(f'invalid job identity: {name}')
        installer_jobs.append({'scenario': scenario, 'runId': run_id, 'jobId': job_id, 'job': name})
    bootstrap_jobs = []
    for image in BOOTSTRAP_IMAGES:
        name = f'Minimal bootstrap ({image})'
        found = [job for job in jobs if job.get('name') == name]
        if len(found) != 1 or found[0].get('status') != 'completed' or found[0].get('conclusion') != 'success':
            raise ValueError(f'missing or unsuccessful job: {name}')
        job_id = found[0].get('id')
        if not isinstance(job_id, int) or isinstance(job_id, bool) or job_id < 1:
            raise ValueError(f'invalid job identity: {name}')
        bootstrap_jobs.append({'image': image, 'runId': run_id, 'jobId': job_id, 'job': name,
                               'coverage': 'minimal-bootstrap-only'})
    return {'schemaVersion': 1, 'candidate': candidate, 'base': base, 'qualificationCommit': commit,
            'runAttempt': attempt, 'modeJobs': modes, 'installerJobs': installer_jobs,
            'bootstrapJobs': bootstrap_jobs, 'baselines': entries}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for arg in ('baselines', 'jobs', 'candidate', 'base', 'output'):
        p.add_argument('--' + arg, type=Path, required=True)
    p.add_argument('--run-id', type=int, required=True)
    p.add_argument('--attempt', type=int, required=True)
    p.add_argument('--commit', required=True)
    p.add_argument('--binaries', type=Path, required=True)
    a = p.parse_args()
    baselines, jobs, candidate, base = (json.loads(path.read_text()) for path in (a.baselines, a.jobs, a.candidate, a.base))
    facts = {}
    for baseline in baselines['baselines']:
        for scenario in SCENARIOS.values():
            key = f"{baseline['version']}-{scenario}"
            artifact = a.binaries / f'qualification-binary-{a.run_id}-{a.attempt}-{key}' / 'xray-binary.json'
            facts[key] = json.loads(artifact.read_text())
    evidence = collect(baselines, jobs, candidate, base, facts, a.run_id, a.commit, a.attempt)
    with a.output.open('x') as f:
        json.dump(evidence, f, sort_keys=True, indent=2)
        f.write('\n')


if __name__ == '__main__':
    main()
