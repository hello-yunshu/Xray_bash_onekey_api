#!/usr/bin/env python3
"""Create or verify an API Release after authenticated qualification.

This does not promote the client-facing JSON. A qualified workflow and its
evidence artifact must already exist on the current trusted API main commit.
"""
import argparse
import base64
import hashlib
import json
import re
import subprocess
import tempfile
from pathlib import Path

import prepare_api_release
import stage_candidate_metadata
import verify_api_release
import verify_qualification_run

REPO = 'hello-yunshu/Xray_bash_onekey_api'


def api(path):
    return json.loads(subprocess.check_output(['gh', 'api', path], text=True))


def exists(path):
    result = subprocess.run(['gh', 'api', path], text=True, capture_output=True)
    if result.returncode == 0:
        return True
    if 'HTTP 404' in result.stderr:
        return False
    raise RuntimeError('GitHub lookup failed; refusing to create a release')


def source_file(path, sha):
    response = api(f'repos/{REPO}/contents/{path}?ref={sha}')
    if response.get('encoding') != 'base64':
        raise ValueError('unexpected GitHub file encoding')
    return json.loads(base64.b64decode(response['content'], validate=False))


def publish(tag, evidence_path, expected_path, candidate_path, run_id, attempt, tested_metadata_path=None):
    if not re.fullmatch(r'api-[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]+', tag):
        raise ValueError('invalid API release tag')
    ref = api(f'repos/{REPO}/git/ref/heads/main')['object']
    sha = ref.get('sha', '')
    if ref.get('type') != 'commit' or not re.fullmatch(r'[0-9a-f]{40}', sha):
        raise ValueError('invalid main branch identity')
    current = source_file('xray_shell_versions.json', sha)
    baselines = source_file('compatibility-baselines.json', sha)
    expected = json.loads(Path(expected_path).read_text())
    candidate = json.loads(Path(candidate_path).read_text())
    evidence_bytes = Path(evidence_path).read_bytes()
    evidence = json.loads(evidence_bytes)
    metadata = stage_candidate_metadata.stage(current, expected, candidate)
    base = evidence.get('base', {})
    if (base.get('xrayVersion'), base.get('installerRef'), base.get('installerSha256')) != tuple(expected.get(k) for k in stage_candidate_metadata.FIELDS):
        raise ValueError('qualification base differs from promotion baseline')
    if base.get('testedVersion') != current.get('xray_tested_version'):
        raise ValueError('qualified fallback version differs from production metadata')
    if tested_metadata_path is not None:
        proposed = json.loads(Path(tested_metadata_path).read_text())
        allowed = {'xray_tested_version', 'xray_tested_at', 'xray_tested_note'}
        if ({k: v for k, v in metadata.items() if k not in allowed} !=
                {k: v for k, v in proposed.items() if k not in allowed}):
            raise ValueError('fallback promotion changed unrelated metadata')
        if evidence.get('candidate', {}).get('testedVersion') != proposed.get('xray_tested_version'):
            raise ValueError('fallback candidate differs from proposed metadata')
        metadata = proposed
    # Validation of complete scenario coverage and candidate equality comes
    # before remote release lookup or any write operation.
    files = prepare_api_release.prepare(metadata, evidence, baselines)
    verify_qualification_run.verify(evidence_bytes, REPO, run_id, sha, attempt)
    # Refuse to create a release if main moved while evidence was checked.
    if api(f'repos/{REPO}/git/ref/heads/main')['object'].get('sha') != sha:
        raise ValueError('API main moved during qualification verification')
    files['SHA256SUMS'] = ''.join(f'{hashlib.sha256(data).hexdigest()}  {name}\n'
                                  for name, data in sorted(files.items())).encode()
    with tempfile.TemporaryDirectory() as tmp:
        directory = Path(tmp)
        for name, data in files.items():
            (directory / name).write_bytes(data)
        release_path = f'repos/{REPO}/releases/tags/{tag}'
        if not exists(release_path):
            # A pre-existing tag without a Release is never adopted blindly.
            if exists(f'repos/{REPO}/git/ref/tags/{tag}'):
                raise ValueError('release tag already exists without a matching release')
            subprocess.run(['gh', 'release', 'create', tag, '--repo', REPO,
                            '--target', sha, '--title', f'API {tag}',
                            '--notes', 'Qualified API metadata snapshot.',
                            *(str(directory / name) for name in sorted(files))], check=True)
        verify_api_release.verify(tag, sha, directory)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tag', required=True)
    for name in ('evidence', 'expected', 'candidate'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--run-id', type=int, required=True)
    parser.add_argument('--attempt', type=int, required=True)
    parser.add_argument('--tested-metadata', type=Path)
    args = parser.parse_args()
    if args.run_id < 1 or args.attempt < 1:
        raise ValueError('invalid run identity')
    publish(args.tag, args.evidence, args.expected, args.candidate, args.run_id, args.attempt, args.tested_metadata)


if __name__ == '__main__':
    main()
