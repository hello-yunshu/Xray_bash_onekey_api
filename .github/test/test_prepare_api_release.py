#!/usr/bin/env python3
import copy
import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('prepare_api_release', ROOT / '.github/scripts/prepare_api_release.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PrepareReleaseTests(unittest.TestCase):
    def setUp(self):
        self.metadata = {'xray_online_version': '26.10.29', 'xray_installer_ref': 'a' * 40,
                         'xray_installer_sha256': 'b' * 64, 'shell_tested_version': '2.8.3'}
        self.baselines = {'schemaVersion': 1, 'baselines': [{'version': '3.2.9', 'commit': 'c' * 40,
                                                               'installSha256': 'd' * 64}]}
        result = {'conclusion': 'success', 'runId': 123, 'job': 'qualification',
                  'environment': {'os': 'ubuntu', 'arch': 'x86_64'}}
        self.evidence = {'schemaVersion': 1, 'offlineRecoveryJob': {'job': 'Recover broken 3.2.9 installation',
                         'runId': 123, 'jobId': 400, 'coverage': 'permission-failure-shell-upgrade-candidate-recovery'},
                         'candidate': {'xrayVersion': '26.10.29',
                         'installerRef': 'a' * 40, 'installerSha256': 'b' * 64},
                         'baselines': [{'version': '3.2.9', 'commit': 'c' * 40,
                         'installSha256': 'd' * 64, 'scenarios': {key: copy.deepcopy(result) for key in
                         ('fresh', 'legacy-upgrade', 'shell-then-upgrade', 'reinstall', 'failure-recovery', 'restart-recovery', 'fallback')}}]}

    def prepare(self):
        return module.prepare(self.metadata, self.evidence, self.baselines)

    def test_deterministic_and_preserves_unrelated_metadata(self):
        self.assertEqual(self.prepare(), self.prepare())
        self.assertIn(b'"shell_tested_version": "2.8.3"', self.prepare()['xray_shell_versions.json'])

    def test_failed_and_missing_scenarios_are_rejected(self):
        scenarios = self.evidence['baselines'][0]['scenarios']
        scenarios['legacy-upgrade']['conclusion'] = 'failure'
        with self.assertRaisesRegex(ValueError, 'not successful'):
            self.prepare()
        del scenarios['legacy-upgrade']
        with self.assertRaisesRegex(ValueError, 'missing required scenario'):
            self.prepare()

    def test_rejects_mixed_candidate_and_wrong_baseline(self):
        self.metadata['xray_online_version'] = '26.3.27'
        with self.assertRaisesRegex(ValueError, 'candidate differ'):
            self.prepare()
        self.metadata['xray_online_version'] = '26.10.29'
        self.evidence['baselines'][0]['commit'] = 'e' * 40
        with self.assertRaisesRegex(ValueError, 'baseline identity mismatch'):
            self.prepare()

    def test_rejects_missing_job_identity(self):
        self.evidence['baselines'][0]['scenarios']['fresh']['runId'] = True
        with self.assertRaisesRegex(ValueError, 'run identity'):
            self.prepare()

    def test_rejects_mismatched_initial_tuple(self):
        self.baselines['baselines'][0]['initial'] = {'xrayVersion': '26.3.27'}
        self.evidence['baselines'][0]['initial'] = {'xrayVersion': '26.10.29'}
        with self.assertRaisesRegex(ValueError, 'initial baseline tuple mismatch'):
            self.prepare()


if __name__ == '__main__':
    unittest.main()
