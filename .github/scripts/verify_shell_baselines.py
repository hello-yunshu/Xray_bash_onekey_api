#!/usr/bin/env python3
"""Verify exact published Shell baselines; never promote or modify releases."""
import hashlib
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

KNOWN_SCENARIOS = frozenset(('fresh', 'direct', 'shell-first', 'reinstall',
                             'failure-recovery', 'restart-recovery', 'fallback'))
LEGACY_SCENARIOS = frozenset(('shell-first', 'reinstall'))


def version_key(value):
    return tuple(map(int, value.split('.')))


def validate_policy(doc):
    """Shells below the minimum direct-upgrade source only qualify the supported paths."""
    minimum = doc.get('minimumDirectUpgradeVersion')
    if not isinstance(minimum, str) or not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', minimum):
        raise ValueError('invalid minimumDirectUpgradeVersion')
    versions = {item.get('version') for item in doc.get('baselines', [])}
    if minimum not in versions:
        raise ValueError('minimumDirectUpgradeVersion is not a declared baseline')
    for item in doc['baselines']:
        scenarios = item.get('scenarios')
        if (not isinstance(scenarios, list) or not scenarios or
                len(set(scenarios)) != len(scenarios) or
                any(not isinstance(scenario, str) or scenario not in KNOWN_SCENARIOS for scenario in scenarios)):
            raise ValueError(f'invalid scenarios for Shell {item.get("version")}')
        if version_key(item['version']) < version_key(minimum):
            if set(scenarios) - LEGACY_SCENARIOS:
                raise ValueError(f'Shell {item["version"]} declares an unsupported direct-upgrade scenario')
            if not LEGACY_SCENARIOS <= set(scenarios):
                raise ValueError(f'Shell {item["version"]} must cover shell-first and reinstall')
        elif 'direct' not in scenarios:
            raise ValueError(f'Shell {item["version"]} must cover direct upgrade')


def main():
    doc = json.loads(Path(sys.argv[1]).read_text())
    if doc.get("schemaVersion") != 1 or doc.get("repository") != "hello-yunshu/Xray_bash_onekey":
        raise ValueError("unsupported baseline document")
    validate_policy(doc)
    baselines = doc.get("baselines")
    if not isinstance(baselines, list) or not baselines:
        raise ValueError("baseline list is empty")
    seen = set()
    for item in baselines:
        version, tag, commit, digest = (item.get(k, "") for k in ("version", "tag", "commit", "installSha256"))
        if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version) or tag != "v" + version or tag in seen:
            raise ValueError("invalid or duplicate baseline tag")
        if not re.fullmatch(r"[0-9a-f]{40}", commit) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise ValueError("invalid baseline identity")
        seen.add(tag)
        repo = doc["repository"]
        ref = json.loads(subprocess.check_output(["gh", "api", f"repos/{repo}/git/ref/tags/{tag}"], text=True))
        obj = ref["object"]
        if obj["type"] == "tag":
            obj = json.loads(subprocess.check_output(["gh", "api", f"repos/{repo}/git/tags/{obj['sha']}"], text=True))["object"]
        if obj["type"] != "commit" or obj["sha"] != commit:
            raise ValueError(f"tag target mismatch: {tag}")
        meta = json.loads(subprocess.check_output(["gh", "release", "view", tag, "--repo", repo, "--json", "isDraft,isPrerelease"], text=True))
        if meta["isDraft"] or meta["isPrerelease"]:
            raise ValueError(f"not a stable release: {tag}")
        with tempfile.TemporaryDirectory() as tmp:
            subprocess.run(["gh", "release", "download", tag, "--repo", repo, "--pattern", "install.sh", "--dir", tmp], check=True)
            blob = (Path(tmp) / "install.sh").read_bytes()
        if hashlib.sha256(blob).hexdigest() != digest:
            raise ValueError(f"release asset mismatch: {tag}")
        if len(re.findall(rb'^shell_version="' + version.encode() + rb'"$', blob, re.MULTILINE)) != 1:
            raise ValueError(f"release asset version mismatch: {tag}")
        print(f"verified {tag} {commit} {digest}")


if __name__ == "__main__":
    main()
