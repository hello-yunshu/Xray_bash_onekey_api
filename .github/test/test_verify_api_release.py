#!/usr/bin/env python3
import hashlib
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('verify_release', ROOT / '.github/scripts/verify_api_release.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class VerifyReleaseTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.directory = Path(self.tmp.name)
        self.tag = 'api-2026.10.30.1'
        self.commit = 'a' * 40
        for name in module.ASSETS - {'SHA256SUMS'}:
            (self.directory / name).write_bytes((name + '\n').encode())
        sums = ''.join(f'{hashlib.sha256((self.directory / name).read_bytes()).hexdigest()}  {name}\n'
                       for name in sorted(module.ASSETS - {'SHA256SUMS'}))
        (self.directory / 'SHA256SUMS').write_text(sums)
        self.meta = {'tagName': self.tag, 'isDraft': False, 'isPrerelease': False,
                     'assets': [{'name': name} for name in module.ASSETS]}
        self.ref = {'object': {'type': 'commit', 'sha': self.commit}}
        self.changed_asset = False

    def verify(self):
        def command(*args):
            return json.dumps(self.ref if args[1] == 'api' else self.meta)
        def download(args, **kwargs):
            target = Path(args[args.index('--dir') + 1])
            for name in module.ASSETS:
                (target / name).write_bytes((self.directory / name).read_bytes())
            if self.changed_asset:
                (target / 'compatibility.json').write_text('changed')
        with patch.object(module, 'command', side_effect=command), patch.object(module.subprocess, 'run', side_effect=download):
            module.verify(self.tag, self.commit, self.directory)

    def test_exact_release(self):
        self.verify()

    def test_rejects_changed_asset(self):
        self.changed_asset = True
        with self.assertRaisesRegex(ValueError, 'asset differs'):
            self.verify()

    def test_rejects_tag_target_and_draft(self):
        self.ref['object']['sha'] = 'b' * 40
        with self.assertRaisesRegex(ValueError, 'target mismatch'):
            self.verify()
        self.ref['object']['sha'] = self.commit
        self.meta['isDraft'] = True
        with self.assertRaisesRegex(ValueError, 'stable tag'):
            self.verify()

    def test_rejects_malformed_expected_checksums(self):
        (self.directory / 'SHA256SUMS').write_text('invalid\n')
        with self.assertRaisesRegex(ValueError, 'SHA256SUMS mismatch'):
            self.verify()


if __name__ == '__main__':
    unittest.main()
