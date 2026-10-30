#!/usr/bin/env python3
"""Read-only verification of a previously published API Release."""
import argparse
import hashlib
import json
import re
import subprocess
import tempfile
from pathlib import Path

REPO = 'hello-yunshu/Xray_bash_onekey_api'
ASSETS = {'xray_shell_versions.json', 'compatibility.json', 'SHA256SUMS'}


def command(*args):
    return subprocess.check_output(args, text=True)


def verify(tag, commit, directory):
    if not re.fullmatch(r'api-[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]+', tag):
        raise ValueError('invalid API release tag')
    if not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise ValueError('invalid expected commit')
    local = Path(directory)
    if {p.name for p in local.iterdir()} != ASSETS or any(not (local / name).is_file() for name in ASSETS):
        raise ValueError('unexpected expected assets')
    expected_sums = ''.join(f'{hashlib.sha256((local / name).read_bytes()).hexdigest()}  {name}\n'
                            for name in sorted(ASSETS - {'SHA256SUMS'}))
    if (local / 'SHA256SUMS').read_text() != expected_sums:
        raise ValueError('expected SHA256SUMS mismatch')
    meta = json.loads(command('gh', 'release', 'view', tag, '--repo', REPO,
                              '--json', 'tagName,isDraft,isPrerelease,assets'))
    if meta['tagName'] != tag or meta['isDraft'] or meta['isPrerelease']:
        raise ValueError('release is not the expected stable tag')
    names = [a['name'] for a in meta['assets']]
    if set(names) != ASSETS or len(names) != len(ASSETS):
        raise ValueError('release asset list mismatch')
    ref = json.loads(command('gh', 'api', f'repos/{REPO}/git/ref/tags/{tag}'))['object']
    if ref['type'] == 'tag':
        ref = json.loads(command('gh', 'api', f'repos/{REPO}/git/tags/{ref["sha"]}'))['object']
    if ref['type'] != 'commit' or ref['sha'] != commit:
        raise ValueError('release tag target mismatch')
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(['gh', 'release', 'download', tag, '--repo', REPO, '--dir', tmp], check=True)
        actual = Path(tmp)
        if {p.name for p in actual.iterdir()} != ASSETS:
            raise ValueError('downloaded release asset list mismatch')
        for name in ASSETS:
            if not (actual / name).is_file() or (actual / name).read_bytes() != (local / name).read_bytes():
                raise ValueError(f'release asset differs: {name}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--commit', required=True)
    parser.add_argument('--directory', type=Path, required=True)
    args = parser.parse_args()
    verify(args.tag, args.commit, args.directory)


if __name__ == '__main__':
    main()
