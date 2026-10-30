#!/usr/bin/env python3
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / '.github/scripts'))
spec = importlib.util.spec_from_file_location('publish', ROOT / '.github/scripts/publish_api_release.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PublishTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        self.old = {'xray_online_version': '26.3.27', 'xray_installer_ref': 'a' * 40,
                    'xray_installer_sha256': 'b' * 64}
        self.new = {'xray_online_version': '26.10.29', 'xray_installer_ref': 'c' * 40,
                    'xray_installer_sha256': 'd' * 64}
        evidence = {'base': {'xrayVersion': self.old['xray_online_version'],
                             'installerRef': self.old['xray_installer_ref'],
                             'installerSha256': self.old['xray_installer_sha256']}}
        for name, doc in (('expected', self.old), ('candidate', self.new), ('evidence', evidence)):
            (self.path / name).write_text(json.dumps(doc))
        self.ref = {'object': {'type': 'commit', 'sha': 'e' * 40}}

    def call(self):
        module.publish('api-2026.10.30.1', self.path / 'evidence', self.path / 'expected',
                       self.path / 'candidate', 100, 1)

    def test_invalid_evidence_never_looks_up_or_creates_release(self):
        with patch.object(module, 'api', return_value=self.ref), \
             patch.object(module, 'source_file', side_effect=[self.old, {}]), \
             patch.object(module.prepare_api_release, 'prepare', side_effect=ValueError('missing scenario')), \
             patch.object(module, 'exists') as exists, patch.object(module.subprocess, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'missing scenario'):
                self.call()
            exists.assert_not_called()
            run.assert_not_called()

    def test_untrusted_run_never_creates_release(self):
        with patch.object(module, 'api', return_value=self.ref), \
             patch.object(module, 'source_file', side_effect=[self.old, {}]), \
             patch.object(module.prepare_api_release, 'prepare', return_value={'compatibility.json': b'{}', 'xray_shell_versions.json': b'{}'}), \
             patch.object(module.verify_qualification_run, 'verify', side_effect=ValueError('untrusted')), \
             patch.object(module, 'exists') as exists, patch.object(module.subprocess, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'untrusted'):
                self.call()
            exists.assert_not_called()
            run.assert_not_called()

    def test_rejects_evidence_from_another_base_before_write(self):
        evidence = json.loads((self.path / 'evidence').read_text())
        evidence['base']['installerRef'] = 'f' * 40
        (self.path / 'evidence').write_text(json.dumps(evidence))
        with patch.object(module, 'api', return_value=self.ref), \
             patch.object(module, 'source_file', side_effect=[self.old, {}]), \
             patch.object(module, 'exists') as exists, patch.object(module.subprocess, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'base differs'):
                self.call()
            exists.assert_not_called()
            run.assert_not_called()

    def test_existing_tag_without_release_is_not_adopted(self):
        with patch.object(module, 'api', return_value=self.ref), \
             patch.object(module, 'source_file', side_effect=[self.old, {}]), \
             patch.object(module.prepare_api_release, 'prepare', return_value={'compatibility.json': b'{}', 'xray_shell_versions.json': b'{}'}), \
             patch.object(module.verify_qualification_run, 'verify'), \
             patch.object(module, 'exists', side_effect=[False, True]), \
             patch.object(module.subprocess, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'tag already exists'):
                self.call()
            run.assert_not_called()

    def test_existing_release_is_verified_without_write(self):
        with patch.object(module, 'api', return_value=self.ref), \
             patch.object(module, 'source_file', side_effect=[self.old, {}]), \
             patch.object(module.prepare_api_release, 'prepare', return_value={'compatibility.json': b'{}', 'xray_shell_versions.json': b'{}'}), \
             patch.object(module.verify_qualification_run, 'verify'), \
             patch.object(module, 'exists', return_value=True), \
             patch.object(module.verify_api_release, 'verify') as verify, patch.object(module.subprocess, 'run') as run:
            self.call()
            verify.assert_called_once()
            run.assert_not_called()

    def test_main_movement_stops_before_release_creation(self):
        moved = {'object': {'type': 'commit', 'sha': 'f' * 40}}
        with patch.object(module, 'api', side_effect=[self.ref, moved]), \
             patch.object(module, 'source_file', side_effect=[self.old, {}]), \
             patch.object(module.prepare_api_release, 'prepare', return_value={'compatibility.json': b'{}', 'xray_shell_versions.json': b'{}'}), \
             patch.object(module.verify_qualification_run, 'verify'), \
             patch.object(module, 'exists') as exists, patch.object(module.subprocess, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'main moved'):
                self.call()
            exists.assert_not_called()
            run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
