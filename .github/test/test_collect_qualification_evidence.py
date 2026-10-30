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
        self.base = dict(self.candidate, testedVersion='25.12.8')
        self.facts = {f'3.2.9-{scenario}': {'version': ('25.12.8' if scenario == 'fallback' else '26.10.29'),
                      'sha256': ('f' * 64 if scenario == 'fallback' else 'a' * 64), 'arch': 'x86_64'}
                      for scenario in module.SCENARIOS.values()}
        self.jobs = [{'name': f'qualify / Legacy upgrade (3.2.9, {scenario})', 'status': 'completed',
                      'conclusion': 'success', 'id': i + 1} for i, scenario in enumerate(module.SCENARIOS.values())]
        self.jobs.extend({'name': f'Full install ({mode})', 'status': 'completed',
                          'conclusion': 'success', 'id': i + 100} for i, mode in enumerate(module.MODES))
        self.jobs.extend({'name': f'Installer smoke ({scenario})', 'status': 'completed',
                          'conclusion': 'success', 'id': i + 200} for i, scenario in enumerate(module.INSTALLER_SCENARIOS))
        self.jobs.extend({'name': f'Minimal bootstrap ({image})', 'status': 'completed',
                          'conclusion': 'success', 'id': i + 300} for i, image in enumerate(module.BOOTSTRAP_IMAGES))

    def collect(self):
        return module.collect(self.baselines, self.jobs, self.candidate, self.base, self.facts, 123, 'e' * 40, 1)

    def test_records_exact_jobs_and_fallback_scope(self):
        result = self.collect()
        self.assertEqual(len(result['baselines'][0]['scenarios']), 6)
        self.assertEqual(result['baselines'][0]['scenarios']['fallback']['environment']['coverage'], 'direct-fallback-function')
        self.assertEqual(result['baselines'][0]['scenarios']['legacy-upgrade']['environment']['coverage'], 'same-version-reinstall')

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

    def test_rejects_missing_or_inconsistent_binary(self):
        del self.facts['3.2.9-direct']
        with self.assertRaisesRegex(ValueError, 'binary evidence'):
            self.collect()
        self.facts['3.2.9-direct'] = {'version': '26.10.29', 'sha256': 'd' * 64, 'arch': 'x86_64'}
        with self.assertRaisesRegex(ValueError, 'inconsistent binary'):
            self.collect()

    def test_distinguishes_legacy_initial_tuple_from_online_base(self):
        initial = {'xrayVersion': '25.12.8', 'installerRef': '1' * 40, 'installerSha256': '2' * 64}
        self.baselines['baselines'][0]['initial'] = initial
        self.facts['3.2.9-failure-recovery']['version'] = '25.12.8'
        self.facts['3.2.9-failure-recovery']['sha256'] = 'f' * 64
        result = self.collect()['baselines'][0]
        self.assertEqual(result['initial'], initial)
        self.assertEqual(result['scenarios']['legacy-upgrade']['environment']['coverage'], 'production-entry')


if __name__ == '__main__':
    unittest.main()
