#!/usr/bin/env python3
import copy
import importlib.util
import json
import os
import sys
import tempfile
from unittest.mock import patch
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('selector', ROOT / '.github/scripts/select_trusted_initials.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class SelectionTests(unittest.TestCase):
    def setUp(self):
        self.primary = dict(xrayVersion='26.3.27', installerRef='a' * 40, installerSha256='b' * 64)
        self.alternative = dict(self.primary, xrayVersion='25.12.8')
        self.doc = dict(trustedInitials=[self.primary, self.alternative], baselines=[
            dict(version=v, initial=copy.deepcopy(self.primary), commit='c' * 40) for v in ('3.2.9', '3.2.10', '3.2.11')])

    def test_missing_primary_selects_trusted_alternative_and_caches_probes(self):
        before = copy.deepcopy(self.doc)
        calls = []
        def probe(item):
            calls.append(item['xrayVersion'])
            if item == self.primary:
                raise subprocess.CalledProcessError(22, 'curl')
        result = module.select(self.doc, probe)
        self.assertEqual(calls, ['26.3.27', '25.12.8'])
        self.assertTrue(all(b['initial'] == self.alternative for b in result['baselines']))
        self.assertEqual(self.doc, before)
        module.validate_selection(self.doc, result)

    def test_all_unavailable_never_uses_latest_or_production(self):
        calls = []
        def probe(item):
            calls.append(item['xrayVersion'])
            raise subprocess.CalledProcessError(22, 'curl')
        with self.assertRaisesRegex(ValueError, 'no available trusted test start'):
            module.select(self.doc, probe)
        self.assertEqual(calls, ['26.3.27', '25.12.8'])

    def test_integrity_or_test_failure_is_not_retried_as_unavailability(self):
        calls = []
        def probe(item):
            calls.append(item)
            raise ValueError('digest mismatch')
        with self.assertRaisesRegex(ValueError, 'digest mismatch'):
            module.select(self.doc, probe)
        self.assertEqual(len(calls), 1)

    def test_fallback_simulation_is_pr_only_and_probes_real_alternative(self):
        with tempfile.TemporaryDirectory() as tmp:
            config, output = Path(tmp) / 'config.json', Path(tmp) / 'output.json'
            config.write_text(json.dumps(self.doc))
            argv = ['selector', str(config), str(output), '--exercise-fallback']
            with patch.object(sys, 'argv', argv), patch.dict(os.environ, GITHUB_EVENT_NAME='workflow_dispatch'):
                with self.assertRaisesRegex(ValueError, 'restricted to PR'):
                    module.main()
                self.assertFalse(output.exists())
            with patch.object(sys, 'argv', argv), patch.dict(os.environ, GITHUB_EVENT_NAME='pull_request'), \
                 patch.object(module, 'available') as probe:
                module.main()
                probe.assert_called_once_with(self.alternative)
            self.assertEqual(json.loads(output.read_text())['baselines'][0]['initial'], self.alternative)

    def test_untrusted_selection_and_unrelated_identity_changes_rejected(self):
        selected = copy.deepcopy(self.doc)
        selected['baselines'][0]['initial']['xrayVersion'] = '99.1.1'
        with self.assertRaisesRegex(ValueError, 'untrusted'):
            module.validate_selection(self.doc, selected)
        selected = copy.deepcopy(self.doc)
        selected['baselines'][0]['commit'] = 'd' * 40
        with self.assertRaisesRegex(ValueError, 'unrelated'):
            module.validate_selection(self.doc, selected)


if __name__ == '__main__':
    unittest.main()
