#!/usr/bin/env python3
"""Choose available, explicitly trusted test starts; never retry failed tests."""
import argparse
import copy
import hashlib
import json
import os
import re
import subprocess
from pathlib import Path


def trusted(doc, baseline):
    choices = [baseline.get('initial'), *doc.get('trustedInitials', [])]
    result = []
    for item in choices:
        if (not isinstance(item, dict) or set(item) != {'xrayVersion', 'installerRef', 'installerSha256'} or
            any(not isinstance(value, str) for value in item.values()) or
            not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', item['xrayVersion']) or
            not re.fullmatch(r'[0-9a-f]{40}', item['installerRef']) or
            not re.fullmatch(r'[0-9a-f]{64}', item['installerSha256'])):
            raise ValueError('invalid trusted initial tuple')
        if item not in result:
            result.append(item)
    return result


def available(item):
    version, ref = item['xrayVersion'], item['installerRef']
    # Only this disposable x86_64 qualification environment is selected here.
    for suffix in ('.zip', '.zip.dgst'):
        subprocess.run(['curl', '-fsSLI', '--retry', '2', '--connect-timeout', '10', '--max-time', '45',
                        '-o', '/dev/null', f'https://github.com/XTLS/Xray-core/releases/download/v{version}/Xray-linux-64{suffix}'], check=True)
    installer = subprocess.check_output(['curl', '-fsSL', '--retry', '2', '--connect-timeout', '10', '--max-time', '45',
                                        f'https://raw.githubusercontent.com/XTLS/Xray-install/{ref}/install-release.sh'])
    if hashlib.sha256(installer).hexdigest() != item['installerSha256']:
        # Integrity failures are not silently treated as an unavailable mirror.
        raise ValueError('trusted installer digest mismatch')


def select(doc, probe=available):
    resolved = copy.deepcopy(doc)
    cache = {}
    for original, baseline in zip(doc['baselines'], resolved['baselines']):
        for item in trusted(doc, original):
            key = json.dumps(item, sort_keys=True)
            if key not in cache:
                try:
                    probe(item)
                    cache[key] = True
                except subprocess.CalledProcessError:
                    cache[key] = False
                    print(f'Test start unavailable: Xray {item["xrayVersion"]}; trying another trusted start')
            if cache[key]:
                baseline['initial'] = copy.deepcopy(item)
                print(f'Shell {baseline["version"]}: selected initial Xray {item["xrayVersion"]}')
                break
        else:
            raise ValueError(f'no available trusted test start for Shell {baseline["version"]}')
    return resolved


def validate_selection(original, selected):
    expected = copy.deepcopy(original)
    if len(selected.get('baselines', [])) != len(original['baselines']):
        raise ValueError('selected baseline identities differ')
    for baseline, chosen in zip(expected['baselines'], selected['baselines']):
        if chosen.get('initial') not in trusted(original, baseline):
            raise ValueError('untrusted selected initial tuple')
        baseline['initial'] = chosen['initial']
    if expected != selected:
        raise ValueError('selection changed unrelated baseline configuration')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('config', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--selection', type=Path)
    parser.add_argument('--exercise-fallback', action='store_true', help='PR-only unavailable-primary simulation')
    args = parser.parse_args()
    original = json.loads(args.config.read_text())
    probe = available
    if args.exercise_fallback:
        if os.environ.get('GITHUB_EVENT_NAME') != 'pull_request' or args.selection:
            raise ValueError('fallback simulation is restricted to PR qualification')
        preferred = [b['initial'] for b in original['baselines']]
        def probe(item):
            if item in preferred:
                raise subprocess.CalledProcessError(22, 'PR-only unavailable-primary simulation')
            available(item)
    selected = json.loads(args.selection.read_text()) if args.selection else select(original, probe)
    validate_selection(original, selected)
    args.output.write_text(json.dumps(selected, sort_keys=True) + '\n')


if __name__ == '__main__':
    main()
