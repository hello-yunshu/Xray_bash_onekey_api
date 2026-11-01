#!/usr/bin/env python3
"""Resolve and wait for a trusted qualification before the publisher checkout."""
import argparse
import json
import os
import re
import subprocess
import time


def resolve(repo, run_id, commit, fetch, pause=time.sleep):
    if run_id < 1 or not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise ValueError('invalid qualification identity')
    for _ in range(24):
        run = fetch(f'repos/{repo}/actions/runs/{run_id}')
        if (run.get('id') != run_id or run.get('event') != 'workflow_dispatch' or
                run.get('head_branch') != 'main' or run.get('head_sha') != commit or
                run.get('path') != '.github/workflows/qualify-release.yml' or
                run.get('repository', {}).get('full_name') != repo or
                run.get('head_repository', {}).get('full_name') != repo):
            raise ValueError('untrusted or stale qualification request')
        if run.get('status') == 'completed':
            if run.get('conclusion') != 'success':
                raise ValueError('qualification did not succeed')
            attempt, started = run.get('run_attempt'), run.get('created_at', '')
            if not isinstance(attempt, int) or isinstance(attempt, bool) or attempt < 1 or not re.fullmatch(r'[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z', started):
                raise ValueError('invalid qualification metadata')
            return dict(sha=commit, run_id=run_id, attempt=attempt, started=started)
        pause(5)
    raise ValueError('qualification did not complete before publish timeout')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-id', type=int, required=True)
    args = parser.parse_args()
    result = resolve(os.environ['GITHUB_REPOSITORY'], args.run_id, os.environ['GITHUB_SHA'],
                     lambda path: json.loads(subprocess.check_output(['gh', 'api', path], text=True)))
    with open(os.environ['GITHUB_OUTPUT'], 'a') as out:
        for key, value in result.items():
            out.write(f'{key}={value}\n')


if __name__ == '__main__':
    main()
