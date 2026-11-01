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


def releases():
    """Every release, drafts included.

    `GET /releases/tags/{tag}` answers 404 for draft releases and a draft owns
    no git tag ref, so a draft created by this script can only be found again
    through the collection listing.
    """
    pages = json.loads(subprocess.check_output(
        ['gh', 'api', '--paginate', '--slurp', f'repos/{REPO}/releases?per_page=100'], text=True))
    return [release for page in pages for release in page]


def find_release(tag):
    matches = [release for release in releases() if release.get('tag_name') == tag]
    if len(matches) > 1:
        raise ValueError('duplicate release tag')
    return matches[0] if matches else None


def source_file(path, sha):
    response = api(f'repos/{REPO}/contents/{path}?ref={sha}')
    if response.get('encoding') != 'base64':
        raise ValueError('unexpected GitHub file encoding')
    return json.loads(base64.b64decode(response['content'], validate=False))


def complete_draft(tag, sha, directory, marker):
    """Resume only our exact draft; never overwrite an existing asset."""
    release = find_release(tag)
    if release is None:
        raise ValueError('draft release is missing before completion')
    if not release.get('draft'):
        return
    if (release.get('body') != marker or release.get('target_commitish') != sha
            or release.get('prerelease') or release.get('tag_name') != tag):
        raise ValueError('draft release identity mismatch')
    assets = release.get('assets', [])
    names = [asset['name'] for asset in assets]
    expected = {p.name for p in directory.iterdir()}
    if len(names) != len(set(names)) or not set(names) <= expected:
        raise ValueError('unexpected draft assets')
    # Check every existing byte before making any write. An interrupted upload
    # with wrong bytes requires investigation, never --clobber.
    with tempfile.TemporaryDirectory() as tmp:
        if names:
            subprocess.run(['gh', 'release', 'download', tag, '--repo', REPO,
                            '--dir', tmp], check=True)
            actual = Path(tmp)
            if {p.name for p in actual.iterdir()} != set(names):
                raise ValueError('downloaded draft asset list mismatch')
            for name in names:
                if (actual / name).read_bytes() != (directory / name).read_bytes():
                    raise ValueError(f'draft asset differs: {name}')
    missing = sorted(expected - set(names))
    if missing:
        subprocess.run(['gh', 'release', 'upload', tag, '--repo', REPO,
                        *(str(directory / name) for name in missing)], check=True)
    # Verify complete bytes and tag before exposing the snapshot publicly.
    verify_api_release.verify(tag, sha, directory, allow_draft=True)
    subprocess.run(['gh', 'release', 'edit', tag, '--repo', REPO,
                    '--draft=false'], check=True)


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
    base = evidence.get('base', {})
    metadata = stage_candidate_metadata.stage(current, expected, candidate)
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
        marker = ('Qualified API metadata snapshot.\n'
                  f'qualification={run_id}; commit={sha}; sha256sums='
                  f'{hashlib.sha256(files["SHA256SUMS"]).hexdigest()}')
        if find_release(tag) is None:
            # A pre-existing tag without a Release is never adopted blindly.
            if exists(f'repos/{REPO}/git/ref/tags/{tag}'):
                raise ValueError('release tag already exists without a matching release')
            subprocess.run(['gh', 'release', 'create', tag, '--repo', REPO,
                            '--target', sha, '--title', f'API {tag}',
                            '--notes', marker, '--draft'], check=True)
        complete_draft(tag, sha, directory, marker)
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
