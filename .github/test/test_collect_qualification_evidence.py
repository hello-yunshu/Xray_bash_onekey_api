#!/usr/bin/env python3
import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('collector', ROOT / '.github/scripts/collect_qualification_evidence.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class CollectionTests(unittest.TestCase):
    def setUp(self):
        self.baselines = {'schemaVersion': 1, 'baselines': [{'version': '3.2.9', 'commit': 'a' * 40,
                                                             'installSha256': 'b' * 64}]}
        self.candidate = {'xrayVersion': '26.10.29', 'installerRef': 'c' * 40, 'installerSha256': 'd' * 64}
        self.jobs = [{'name': f'qualify / Legacy upgrade (3.2.9, {scenario})', 'status': 'completed',
                      'conclusion': 'success', 'id': i + 1} for i, scenario in enumerate(module.SCENARIOS.values())]

    def collect(self):
        return module.collect(self.baselines, self.jobs, self.candidate, 123, 'e' * 40, 1)

    def test_records_exact_jobs_and_fallback_scope(self):
        result = self.collect()
        self.assertEqual(len(result['baselines'][0]['scenarios']), 6)
        self.assertEqual(result['baselines'][0]['scenarios']['fallback']['environment']['coverage'], 'direct-fallback-function')

    def test_fails_closed_for_failure_missing_or_duplicate_job(self):
        self.jobs[0]['conclusion'] = 'failure'
        with self.assertRaisesRegex(ValueError, 'unsuccessful'):
            self.collect()
        self.jobs[0]['conclusion'] = 'success'
        self.jobs.append(self.jobs[0].copy())
        with self.assertRaisesRegex(ValueError, 'unsuccessful'):
            self.collect()
        self.jobs.pop()
        self.jobs.pop()
        with self.assertRaisesRegex(ValueError, 'unsuccessful'):
            self.collect()

    def test_rejects_invalid_candidate(self):
        self.candidate['installerSha256'] = 'invalid'
        with self.assertRaisesRegex(ValueError, 'invalid candidate'):
            self.collect()


if __name__ == '__main__':
    unittest.main()
