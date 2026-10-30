#!/usr/bin/env python3
import copy
import json
import sys
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / '.github/scripts'))
import verify_tested_promotion as module
from test_prepare_api_release import PrepareReleaseTests


class TestedPromotionTests(unittest.TestCase):
    def setUp(self):
        fixture = PrepareReleaseTests()
        fixture.setUp()
        self.current = fixture.metadata
        self.current['xray_tested_version'] = '25.12.8'
        self.baselines = fixture.baselines
        self.evidence = fixture.evidence
        self.evidence['base'] = dict(self.evidence['candidate'], testedVersion='25.12.8')
        self.evidence['candidate']['testedVersion'] = '26.3.27'
        self.evidence['baselines'][0]['scenarios']['fallback']['binary'] = {'version': '26.3.27'}

    def check(self):
        with mock.patch.object(module.verify_qualification_run, 'verify') as authentic:
            module.verify(json.dumps(self.evidence).encode(), self.current, self.baselines,
                          '26.3.27', 123, 1, 'c' * 40)
            authentic.assert_called_once()

    def test_accepts_matching_tuple_and_fallback(self):
        self.check()

    def test_rejects_stale_tuple_or_fallback(self):
        for field, value in [('xray_online_version', '26.4.1'), ('xray_tested_version', '26.1.1')]:
            original = copy.deepcopy(self.current)
            self.current[field] = value
            with self.assertRaises(ValueError):
                self.check()
            self.current = original

    def test_rejects_untested_fallback_binary(self):
        self.evidence['baselines'][0]['scenarios']['fallback']['binary']['version'] = '25.12.8'
        with self.assertRaisesRegex(ValueError, 'fallback binary'):
            self.check()


if __name__ == '__main__':
    unittest.main()
