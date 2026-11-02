#!/usr/bin/env python3
"""Local consistency checks for the version metadata pair and baselines."""
import importlib.util
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('baseline', ROOT / '.github/scripts/verify_shell_baselines.py')
baseline = importlib.util.module_from_spec(spec)
spec.loader.exec_module(baseline)


class VersionConsistencyTests(unittest.TestCase):
    def setUp(self):
        self.tested = json.loads((ROOT / 'tested_versions.json').read_text())
        self.online = json.loads((ROOT / 'xray_shell_versions.json').read_text())
        self.baselines = json.loads((ROOT / 'compatibility-baselines.json').read_text())

    def test_tested_shell_matches_between_the_two_files(self):
        self.assertEqual(self.tested['shell'], self.online['shell_tested_version'])

    def test_online_shell_has_an_exact_baseline(self):
        version = self.online['shell_online_version']
        matches = [item for item in self.baselines['baselines'] if item['version'] == version]
        self.assertEqual(len(matches), 1, f'no unique baseline for online Shell {version}')
        item = matches[0]
        self.assertEqual(item['tag'], f'v{version}')
        self.assertEqual(item['installSha256'], self.online['shell_release_sha256'])

    def test_online_shell_is_the_newest_baseline(self):
        newest = max(self.baselines['baselines'], key=lambda item: baseline.version_key(item['version']))
        self.assertEqual(newest['version'], self.online['shell_online_version'])

    def test_baseline_policy_is_valid(self):
        baseline.validate_policy(self.baselines)


if __name__ == '__main__':
    unittest.main()
