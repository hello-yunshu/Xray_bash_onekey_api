#!/usr/bin/env python3
"""Deduplicate automatic qualification; retry unchanged failures at most daily."""
import datetime as dt
import hashlib
import json
import os
import subprocess
from pathlib import Path


def decision(runs, key, now):
    matching = [r for r in runs if r.get('display_title') == key and r.get('event') == 'workflow_dispatch'
                and r.get('head_branch') == 'main']
    if any(r['status'] != 'completed' for r in matching):
        return False, 'Matching qualification still active'
    if matching:
        latest = max(matching, key=lambda r: r['created_at'])
        elapsed = now - dt.datetime.fromisoformat(latest['created_at'].replace('Z', '+00:00'))
        # Successful evidence may need retry when a concurrent main update blocked
        # publishing. Allow one retry per day, not every hourly health failure.
        if elapsed < dt.timedelta(hours=24):
            return False, 'Unchanged combination is in its 24-hour retry cooldown'
    return True, 'New combination or daily retry due'


def dispatch(values, repo):
    metadata = json.loads(Path('xray_shell_versions.json').read_text())
    relevant = {k: v for k, v in metadata.items() if k.startswith('xray_') or k.startswith('shell_')}
    identity = json.dumps([values, relevant], sort_keys=True).encode()
    for path in sorted([Path('compatibility-baselines.json'), *Path('.github/scripts').glob('*'), *Path('.github/workflows').glob('*.yml')]):
        if path.is_file():
            identity += str(path).encode() + path.read_bytes()
    key = 'auto-xray-' + hashlib.sha256(identity).hexdigest()
    now = dt.datetime.now(dt.timezone.utc)
    since = (now - dt.timedelta(days=7)).strftime('%Y-%m-%dT%H:%M:%SZ')
    pages = json.loads(subprocess.check_output(['gh', 'api', '--paginate', '--slurp',
        f'repos/{repo}/actions/workflows/qualify-release.yml/runs?event=workflow_dispatch&branch=main&per_page=100&created=>={since}'], text=True))
    runs = [run for page in pages for run in page['workflow_runs']]
    allowed, reason = decision(runs, key, now)
    print(f'{key}: {reason}')
    if not allowed:
        return
    # The qualifier run-name persists this key in GitHub, without state commits.
    args = ['gh', 'workflow', 'run', 'qualify-release.yml', '--repo', repo, '--ref', 'main']
    for name, value in dict(base_version=values['BASE_VERSION'], base_installer_ref=values['BASE_REF'],
                            base_installer_sha256=values['BASE_SHA'], candidate_version=values['CANDIDATE_VERSION'],
                            candidate_installer_ref=values['CANDIDATE_REF'], candidate_installer_sha256=values['CANDIDATE_SHA'],
                            automation_key=key).items():
        args += ['-f', f'{name}={value}']
    subprocess.run(args, check=True)


def main():
    repo = os.environ['GITHUB_REPOSITORY']
    values = {k: os.environ[k] for k in ('BASE_VERSION', 'BASE_REF', 'BASE_SHA', 'CANDIDATE_VERSION', 'CANDIDATE_REF', 'CANDIDATE_SHA')}
    # A broken new installer must not prevent testing a new core with the
    # already qualified installer. Both paths still require the full matrix.
    if values['CANDIDATE_VERSION'] != values['BASE_VERSION'] and values['CANDIDATE_REF'] != values['BASE_REF']:
        dispatch(dict(values, CANDIDATE_REF=values['BASE_REF'], CANDIDATE_SHA=values['BASE_SHA']), repo)
    dispatch(values, repo)


if __name__ == '__main__':
    main()
