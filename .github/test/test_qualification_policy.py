#!/usr/bin/env python3
import copy
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / '.github/scripts'))
import qualification_policy as module


class PolicyTests(unittest.TestCase):
    def setUp(self):
        self.candidate = {'xrayVersion': '26.10.31', 'installerRef': 'a' * 40, 'installerSha256': 'b' * 64}
        self.entry = {'baseline': '3.2.9', 'scenarios': ['fresh', 'legacy-upgrade', 'reinstall', 'fallback'],
                      'candidate': dict(self.candidate), 'diagnostic': 'permission denied observed',
                      'reason': 'Shell 3.2.9 assigns configuration ownership incompatible with this installer'}
        self.doc = {'baselines': [{'version': '3.2.9'}], 'expectedIncompatible': [copy.deepcopy(self.entry)]}

    def test_exact_match_only(self):
        for scenario in self.entry['scenarios']:
            self.assertEqual(module.expected(self.doc, '3.2.9', scenario, self.candidate), self.entry)
        self.assertIsNone(module.expected(self.doc, '3.2.9', 'shell-then-upgrade', self.candidate))
        self.assertIsNone(module.expected(self.doc, '3.2.10', 'fresh', self.candidate))
        other = dict(self.candidate, installerRef='c' * 40)
        self.assertIsNone(module.expected(self.doc, '3.2.9', 'fresh', other))
        self.assertTrue(module.any_for_baseline(self.doc, '3.2.9', self.candidate))

    def test_rejects_unknown_baseline_scenario_diagnostic_or_candidate(self):
        mutations = [('baseline', '9.9.9'), ('diagnostic', 'any failure'), ('reason', '')]
        for field, value in mutations:
            with self.subTest(field=field):
                entry = copy.deepcopy(self.entry)
                entry[field] = value
                doc = {'baselines': self.doc['baselines'], 'expectedIncompatible': [entry]}
                with self.assertRaises(ValueError):
                    module.validate(doc)
        for scenarios in ([], ['restart-recovery'], ['fresh', 'fresh'], ['unknown']):
            with self.subTest(scenarios=scenarios):
                entry = copy.deepcopy(self.entry)
                entry['scenarios'] = scenarios
                with self.assertRaises(ValueError):
                    module.validate({'baselines': self.doc['baselines'], 'expectedIncompatible': [entry]})
        entry = copy.deepcopy(self.entry)
        entry['candidate']['installerRef'] = 'not-a-commit'
        with self.assertRaisesRegex(ValueError, 'candidate'):
            module.validate({'baselines': self.doc['baselines'], 'expectedIncompatible': [entry]})

    def test_rejects_duplicate_and_extra_fields(self):
        with self.assertRaisesRegex(ValueError, 'duplicate'):
            module.validate({'baselines': self.doc['baselines'],
                             'expectedIncompatible': [copy.deepcopy(self.entry), copy.deepcopy(self.entry)]})
        entry = copy.deepcopy(self.entry)
        entry['allowAnything'] = True
        with self.assertRaisesRegex(ValueError, 'declaration'):
            module.validate({'baselines': self.doc['baselines'], 'expectedIncompatible': [entry]})


if __name__ == '__main__':
    unittest.main()
