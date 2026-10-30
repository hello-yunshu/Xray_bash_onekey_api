#!/usr/bin/env python3
"""Exercise baseline identity checks without trusting live GitHub responses."""
import hashlib
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('baseline', ROOT / '.github/scripts/verify_shell_baselines.py')
baseline = importlib.util.module_from_spec(spec)
spec.loader.exec_module(baseline)


class VerifyBaselines(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / 'baselines.json'
        self.blob = b'shell_version="3.2.9"\n'
        self.doc = {'schemaVersion': 1, 'repository': 'hello-yunshu/Xray_bash_onekey', 'baselines': [
            {'version': '3.2.9', 'tag': 'v3.2.9', 'commit': 'a' * 40,
             'installSha256': hashlib.sha256(self.blob).hexdigest()}]}
        self.ref = {'object': {'type': 'commit', 'sha': 'a' * 40}}
        self.meta = {'isDraft': False, 'isPrerelease': False}

    def verify(self):
        self.path.write_text(json.dumps(self.doc))

        def output(args, **kwargs):
            return json.dumps(self.ref if args[1] == 'api' else self.meta)

        def download(args, **kwargs):
            (Path(args[args.index('--dir') + 1]) / 'install.sh').write_bytes(self.blob)

        with patch.object(sys, 'argv', ['verify', str(self.path)]), \
             patch.object(baseline.subprocess, 'check_output', side_effect=output), \
             patch.object(baseline.subprocess, 'run', side_effect=download):
            baseline.main()

    def test_valid_published_asset(self):
        self.verify()

    def test_reject_tag_mismatch(self):
        self.ref['object']['sha'] = 'b' * 40
        with self.assertRaisesRegex(ValueError, 'tag target mismatch'):
            self.verify()

    def test_reject_changed_asset(self):
        self.blob += b'changed\n'
        with self.assertRaisesRegex(ValueError, 'asset mismatch'):
            self.verify()

    def test_reject_wrong_embedded_version(self):
        self.blob = b'shell_version="3.2.10"\n'
        self.doc['baselines'][0]['installSha256'] = hashlib.sha256(self.blob).hexdigest()
        with self.assertRaisesRegex(ValueError, 'version mismatch'):
            self.verify()

    def test_reject_prerelease_and_duplicate(self):
        self.meta['isPrerelease'] = True
        with self.assertRaisesRegex(ValueError, 'not a stable release'):
            self.verify()
        self.meta['isPrerelease'] = False
        self.doc['baselines'].append(self.doc['baselines'][0].copy())
        with self.assertRaisesRegex(ValueError, 'duplicate'):
            self.verify()


if __name__ == '__main__':
    unittest.main()
