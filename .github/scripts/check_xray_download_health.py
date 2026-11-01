#!/usr/bin/env python3
"""Check production/fallback download availability; never change metadata."""
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

ARCHES = ('64', 'arm64-v8a')


def probe(url):
    # HEAD follows the same redirects as installation without downloading large zips.
    subprocess.run(['curl', '--fail', '--silent', '--show-error', '--location',
                    '--head', '--retry', '2', '--connect-timeout', '10',
                    '--max-time', '45', '--output', '/dev/null', url], check=True)


def check(metadata, fetch, head):
    failures = []
    for version in sorted({metadata['xray_online_version'], metadata['xray_tested_version']}):
        if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version):
            raise ValueError('invalid version')
        try:
            release = fetch(f'repos/XTLS/Xray-core/releases/tags/v{version}')
            if release.get('draft') or release.get('prerelease') or release.get('tag_name') != f'v{version}':
                raise ValueError('not the expected stable release')
            names = {a['name'] for a in release['assets']}
            for arch in ARCHES:
                for suffix in ('.zip', '.zip.dgst'):
                    name = f'Xray-linux-{arch}{suffix}'
                    if name not in names:
                        raise ValueError(f'missing asset {name}')
                    head(f'https://github.com/XTLS/Xray-core/releases/download/v{version}/{name}')
        except (ValueError, KeyError, subprocess.CalledProcessError) as exc:
            failures.append(f'Xray {version}: {exc}')
    ref, digest = metadata['xray_installer_ref'], metadata['xray_installer_sha256']
    if not re.fullmatch(r'[a-f0-9]{40}', ref) or not re.fullmatch(r'[a-f0-9]{64}', digest):
        raise ValueError('invalid installer identity')
    try:
        installer = subprocess.check_output(['curl', '-fsSL', '--retry', '2', '--connect-timeout', '10',
                                             '--max-time', '45', f'https://raw.githubusercontent.com/XTLS/Xray-install/{ref}/install-release.sh'])
        if hashlib.sha256(installer).hexdigest() != digest:
            raise ValueError('installer SHA256 mismatch')
    except (ValueError, subprocess.CalledProcessError) as exc:
        failures.append(f'Installer: {exc}')
    return failures


def main():
    metadata = json.loads(Path('xray_shell_versions.json').read_text())
    failures = check(metadata, lambda path: json.loads(subprocess.check_output(['gh', 'api', path], text=True)), probe)
    report = ('Download availability (Linux x86_64 / arm64; not a runtime qualification)\n' +
              ('\n'.join(failures) if failures else 'All checked endpoints available.'))
    print(report)
    import os
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as out:
            out.write(report + '\n')
    return bool(failures)


if __name__ == '__main__':
    sys.exit(main())
