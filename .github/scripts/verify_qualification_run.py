#!/usr/bin/env python3
"""Check a qualification artifact against an explicitly pinned trusted Actions run.

This is a read-only verifier. A caller must independently obtain trusted SHA and
expected candidate inputs; never treat values from the artifact as authority.
"""
import argparse
import json
import re
import subprocess
import tempfile
from pathlib import Path
from collect_qualification_evidence import MODES, SCENARIOS


def api(path):
    return json.loads(subprocess.check_output(['gh', 'api', path], text=True))


def verify(evidence_bytes, repo, run_id, trusted_sha, attempt):
    if repo != 'hello-yunshu/Xray_bash_onekey_api' or not re.fullmatch(r'[0-9a-f]{40}', trusted_sha):
        raise ValueError('invalid trusted repository or commit')
    run = api(f'repos/{repo}/actions/runs/{run_id}')
    if (run.get('id') != run_id or run.get('head_sha') != trusted_sha or
            run.get('path') != '.github/workflows/qualify-release.yml' or
            run.get('event') not in ('schedule', 'workflow_dispatch') or
            run.get('status') != 'completed' or run.get('conclusion') != 'success' or
            run.get('run_attempt') != attempt or
            run.get('repository', {}).get('full_name') != repo):
        raise ValueError('untrusted or incomplete qualification run')
    evidence = json.loads(evidence_bytes)
    if evidence.get('qualificationCommit') != trusted_sha or evidence.get('runAttempt') != attempt:
        raise ValueError('qualification evidence identity mismatch')
    jobs = []
    page = 1
    while True:
        response = api(f'repos/{repo}/actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100&page={page}')
        batch = response['jobs']
        jobs.extend(batch)
        if len(batch) < 100:
            break
        page += 1
    mode_jobs = evidence.get('modeJobs')
    if not isinstance(mode_jobs, list) or len(mode_jobs) != len(MODES) or {j.get('mode') for j in mode_jobs} != set(MODES):
        raise ValueError('missing full installation modes')
    for result in mode_jobs:
        name = f"Full install ({result['mode']})"
        matches = [job for job in jobs if job.get('id') == result.get('jobId')]
        if result.get('runId') != run_id or result.get('job') != name or len(matches) != 1 or matches[0].get('name') != name or matches[0].get('status') != 'completed' or matches[0].get('conclusion') != 'success':
            raise ValueError('full installation job missing or unsuccessful')
    for baseline in evidence['baselines']:
        version = baseline['version']
        if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version):
            raise ValueError('invalid baseline version')
        for scenario, result in baseline['scenarios'].items():
            if scenario not in SCENARIOS:
                raise ValueError('unknown qualification scenario')
            expected_name = f'qualify / Legacy upgrade ({version}, {SCENARIOS[scenario]})'
            job_id = result.get('jobId')
            if result.get('job') != expected_name or result.get('runId') != run_id or not isinstance(job_id, int) or isinstance(job_id, bool):
                raise ValueError('scenario references a different run or invalid job')
            matches = [job for job in jobs if job.get('id') == job_id]
            if len(matches) != 1 or matches[0].get('name') != result.get('job') or matches[0].get('status') != 'completed' or matches[0].get('conclusion') != 'success':
                raise ValueError('scenario job is missing or unsuccessful')
    artifact_name = f'qualification-evidence-{run_id}-{attempt}'
    artifacts = []
    page = 1
    while True:
        batch = api(f'repos/{repo}/actions/runs/{run_id}/artifacts?per_page=100&page={page}')['artifacts']
        artifacts.extend(batch)
        if len(batch) < 100:
            break
        page += 1
    matching = [a for a in artifacts if a.get('name') == artifact_name and not a.get('expired')]
    if len(matching) != 1:
        raise ValueError('missing or ambiguous qualification artifact')
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(['gh', 'run', 'download', str(run_id), '--repo', repo,
                        '--name', artifact_name, '--dir', tmp], check=True)
        paths = list(Path(tmp).rglob('*'))
        if len(paths) != 1 or not paths[0].is_file() or paths[0].name != 'compatibility.json':
            raise ValueError('unexpected qualification artifact contents')
        if paths[0].read_bytes() != evidence_bytes:
            raise ValueError('qualification artifact bytes differ')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--repository', required=True)
    parser.add_argument('--run-id', type=int, required=True)
    parser.add_argument('--attempt', type=int, required=True)
    parser.add_argument('--trusted-sha', required=True)
    args = parser.parse_args()
    if args.run_id < 1 or args.attempt < 1:
        raise ValueError('invalid run identity')
    verify(args.evidence.read_bytes(), args.repository, args.run_id, args.trusted_sha, args.attempt)


if __name__ == '__main__':
    main()
