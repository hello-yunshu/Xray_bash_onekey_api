#!/usr/bin/env python3
import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('stage', ROOT / '.github/scripts/stage_candidate_metadata.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class StageCandidateTests(unittest.TestCase):
    def setUp(self):
        self.old = {'xray_online_version': '26.3.27', 'xray_installer_ref': 'a' * 40,
                    'xray_installer_sha256': 'b' * 64, 'shell_online_version': '3.2.10',
                    'xray_tested_version': '25.12.8'}
        self.new = {'xray_online_version': '26.10.29', 'xray_installer_ref': 'c' * 40,
                    'xray_installer_sha256': 'd' * 64}

    def test_stage_tuple_together_preserving_unrelated_changes(self):
        current = dict(self.old, shell_online_version='3.2.11')
        staged = module.stage(current, self.old, self.new)
        self.assertEqual([staged[k] for k in module.FIELDS], [self.new[k] for k in module.FIELDS])
        self.assertEqual(staged['shell_online_version'], '3.2.11')
        self.assertEqual(staged['xray_tested_version'], '25.12.8')
        self.assertEqual(current['xray_online_version'], '26.3.27')

    def test_rejects_concurrent_tuple_change(self):
        for key in module.FIELDS:
            changed = dict(self.old, **{key: self.new[key]})
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, 'baseline changed'):
                module.stage(changed, self.old, self.new)

    def test_rejects_downgrade_and_invalid_identity(self):
        with self.assertRaisesRegex(ValueError, 'downgrade'):
            module.stage(self.new, self.new, self.old)
        with self.assertRaisesRegex(ValueError, 'installer identity'):
            module.stage(self.old, self.old, dict(self.new, xray_installer_sha256='invalid'))

    def test_downgrade_does_not_bypass_baseline_check(self):
        with self.assertRaisesRegex(ValueError, 'baseline changed'):
            module.stage(dict(self.new, xray_installer_ref='e' * 40), self.new, self.old)


if __name__ == '__main__':
    unittest.main()
