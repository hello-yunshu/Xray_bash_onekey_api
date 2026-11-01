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
                    'xray_installer_sha256': 'b' * 64, 'xray_tested_version': '25.12.8'}
        self.new = {'xray_online_version': '26.10.29', 'xray_installer_ref': 'c' * 40,
                    'xray_installer_sha256': 'd' * 64}
        evidence = {'base': {'xrayVersion': self.old['xray_online_version'],
                             'installerRef': self.old['xray_installer_ref'],
                             'installerSha256': self.old['xray_installer_sha256'],
                             'testedVersion': self.old['xray_tested_version']}}
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

    def test_rejects_changed_fallback_before_release_write(self):
        evidence = json.loads((self.path / 'evidence').read_text())
        evidence['base']['testedVersion'] = '25.12.7'
        (self.path / 'evidence').write_text(json.dumps(evidence))
        with patch.object(module, 'api', return_value=self.ref), \
             patch.object(module, 'source_file', side_effect=[self.old, {}]), \
             patch.object(module, 'exists') as exists, patch.object(module.subprocess, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'fallback version differs'):
                self.call()
            exists.assert_not_called()
            run.assert_not_called()

    def test_existing_tag_without_release_is_not_adopted(self):
        with patch.object(module, 'api', return_value=self.ref), \
             patch.object(module, 'source_file', side_effect=[self.old, {}]), \
             patch.object(module.prepare_api_release, 'prepare', return_value={'compatibility.json': b'{}', 'xray_shell_versions.json': b'{}'}), \
             patch.object(module.verify_qualification_run, 'verify'), \
             patch.object(module, 'find_release', return_value=None), \
             patch.object(module, 'exists', return_value=True), \
             patch.object(module.subprocess, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'tag already exists'):
                self.call()
            run.assert_not_called()

    def test_existing_release_is_verified_without_write(self):
        release = {'tag_name': 'api-2026.10.30.1', 'draft': False}
        with patch.object(module, 'api', return_value=self.ref), \
             patch.object(module, 'source_file', side_effect=[self.old, {}]), \
             patch.object(module.prepare_api_release, 'prepare', return_value={'compatibility.json': b'{}', 'xray_shell_versions.json': b'{}'}), \
             patch.object(module.verify_qualification_run, 'verify'), \
             patch.object(module, 'find_release', return_value=release), \
             patch.object(module, 'exists') as exists, \
             patch.object(module, 'complete_draft') as complete, \
             patch.object(module.verify_api_release, 'verify') as verify, patch.object(module.subprocess, 'run') as run:
            self.call()
            exists.assert_not_called()
            complete.assert_called_once()
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

    def test_fallback_snapshot_rejects_unrelated_changes(self):
        evidence = json.loads((self.path / 'evidence').read_text())
        evidence['candidate'] = {'testedVersion': '26.3.27'}
        (self.path / 'evidence').write_text(json.dumps(evidence))
        proposed = dict(self.old, xray_tested_version='26.3.27', extra='unexpected')
        (self.path / 'proposed').write_text(json.dumps(proposed))
        (self.path / 'candidate').write_text(json.dumps(self.old))
        with patch.object(module, 'api', return_value=self.ref), \
             patch.object(module, 'source_file', side_effect=[self.old, {}]), \
             patch.object(module, 'exists') as exists:
            with self.assertRaisesRegex(ValueError, 'unrelated metadata'):
                module.publish('api-2026.10.30.1', self.path / 'evidence', self.path / 'expected',
                               self.path / 'candidate', 100, 1, self.path / 'proposed')
            exists.assert_not_called()

    def test_fallback_snapshot_is_published_before_metadata_promotion(self):
        evidence = json.loads((self.path / 'evidence').read_text())
        evidence['candidate'] = {'testedVersion': '26.3.27'}
        (self.path / 'evidence').write_text(json.dumps(evidence))
        proposed = dict(self.old, xray_tested_version='26.3.27', xray_tested_at='2026-10-30T10:00:00Z')
        (self.path / 'proposed').write_text(json.dumps(proposed))
        (self.path / 'candidate').write_text(json.dumps(self.old))
        with patch.object(module, 'api', return_value=self.ref), \
             patch.object(module, 'source_file', side_effect=[self.old, {}]), \
             patch.object(module.prepare_api_release, 'prepare', return_value={'compatibility.json': b'{}', 'xray_shell_versions.json': b'{}'}) as prepare, \
             patch.object(module.verify_qualification_run, 'verify'), \
             patch.object(module, 'find_release', return_value=None), \
             patch.object(module, 'exists', return_value=False), \
             patch.object(module, 'complete_draft'), \
             patch.object(module.verify_api_release, 'verify') as verify, \
             patch.object(module.subprocess, 'run') as run:
            module.publish('api-2026.10.30.1', self.path / 'evidence', self.path / 'expected',
                           self.path / 'candidate', 100, 1, self.path / 'proposed')
            self.assertEqual(prepare.call_args.args[0], proposed)
            run.assert_called_once()
            verify.assert_called_once()

    def test_draft_resume_uploads_only_missing_assets(self):
        directory = self.path / 'assets'
        directory.mkdir()
        for name in module.verify_api_release.ASSETS:
            (directory / name).write_bytes(b'expected')
        meta = {'draft': True, 'body': 'marker', 'target_commitish': 'e' * 40,
                'prerelease': False, 'tag_name': 'api-2026.10.30.1',
                'assets': [{'name': 'compatibility.json'}]}
        calls = []

        def run(args, **kwargs):
            calls.append(args)
            if args[2] == 'download':
                Path(args[-1], 'compatibility.json').write_bytes(b'expected')

        with patch.object(module, 'find_release', return_value=meta), \
             patch.object(module.subprocess, 'run', side_effect=run), \
             patch.object(module.verify_api_release, 'verify') as verify:
            module.complete_draft('api-2026.10.30.1', 'e' * 40, directory, 'marker')
        upload = calls[1]
        self.assertEqual(upload[2], 'upload')
        self.assertEqual({Path(p).name for p in upload[6:]},
                         {'SHA256SUMS', 'xray_shell_versions.json'})
        self.assertNotIn('--clobber', upload)
        verify.assert_called_once_with('api-2026.10.30.1', 'e' * 40, directory, allow_draft=True)
        self.assertEqual(calls[-1][2], 'edit')

    def test_draft_identity_and_bytes_fail_before_write(self):
        directory = self.path / 'assets'
        directory.mkdir()
        (directory / 'compatibility.json').write_bytes(b'expected')
        meta = {'draft': True, 'body': 'marker', 'target_commitish': 'e' * 40,
                'prerelease': False, 'tag_name': 'api-2026.10.30.1',
                'assets': [{'name': 'compatibility.json'}]}
        for field, value in [('body', 'foreign'), ('target_commitish', 'f' * 40),
                             ('prerelease', True), ('assets', [{'name': 'unexpected'}])]:
            with self.subTest(field=field), patch.object(module, 'find_release', return_value=dict(meta, **{field: value})), \
                 patch.object(module.subprocess, 'run') as run:
                with self.assertRaises(ValueError):
                    module.complete_draft('api-2026.10.30.1', 'e' * 40, directory, 'marker')
                run.assert_not_called()

        def download(args, **kwargs):
            Path(args[-1], 'compatibility.json').write_bytes(b'corrupt')

        with patch.object(module, 'find_release', return_value=meta), \
             patch.object(module.subprocess, 'run', side_effect=download) as run:
            with self.assertRaisesRegex(ValueError, 'draft asset differs'):
                module.complete_draft('api-2026.10.30.1', 'e' * 40, directory, 'marker')
            self.assertEqual(run.call_count, 1)

    def test_incomplete_upload_never_publishes(self):
        directory = self.path / 'assets'
        directory.mkdir()
        (directory / 'compatibility.json').write_bytes(b'expected')
        meta = {'draft': True, 'body': 'marker', 'target_commitish': 'e' * 40,
                'prerelease': False, 'tag_name': 'api-2026.10.30.1', 'assets': []}
        with patch.object(module, 'find_release', return_value=meta), \
             patch.object(module.subprocess, 'run') as run, \
             patch.object(module.verify_api_release, 'verify', side_effect=ValueError('missing asset')):
            with self.assertRaisesRegex(ValueError, 'missing asset'):
                module.complete_draft('api-2026.10.30.1', 'e' * 40, directory, 'marker')
            self.assertEqual(run.call_count, 1)
            self.assertEqual(run.call_args.args[0][2], 'upload')

    def test_draft_is_resolved_through_the_collection_listing(self):
        listed = [{'tag_name': 'api-2026.10.29.9', 'draft': False},
                  {'tag_name': 'api-2026.10.30.1', 'draft': True}]
        with patch.object(module.subprocess, 'check_output',
                          return_value=json.dumps([listed[:1], listed[1:]])) as output:
            self.assertEqual(module.find_release('api-2026.10.30.1'), listed[1])
        command = output.call_args.args[0]
        # The tag endpoint answers 404 for drafts and must never be used here.
        self.assertIn('--slurp', command)
        self.assertTrue(any('releases?per_page=100' in part for part in command))
        self.assertFalse(any('releases/tags' in part for part in command))

    def test_absent_release_is_not_an_error(self):
        listed = [{'tag_name': 'api-2026.10.29.9', 'draft': False}]
        with patch.object(module.subprocess, 'check_output', return_value=json.dumps([listed])):
            self.assertIsNone(module.find_release('api-2026.10.30.1'))

    def test_duplicate_release_tag_is_rejected(self):
        listed = [{'tag_name': 'api-2026.10.30.1', 'draft': True},
                  {'tag_name': 'api-2026.10.30.1', 'draft': False}]
        with patch.object(module.subprocess, 'check_output', return_value=json.dumps([listed])):
            with self.assertRaisesRegex(ValueError, 'duplicate release tag'):
                module.find_release('api-2026.10.30.1')

    def test_complete_draft_requires_an_existing_draft(self):
        directory = self.path / 'assets'
        directory.mkdir()
        (directory / 'compatibility.json').write_bytes(b'expected')
        with patch.object(module, 'find_release', return_value=None), \
             patch.object(module.subprocess, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'missing before completion'):
                module.complete_draft('api-2026.10.30.1', 'e' * 40, directory, 'marker')
            run.assert_not_called()

    def test_rollback_flag_cannot_bypass_downgrade_guard(self):
        newer = dict(self.new, xray_tested_version=self.old['xray_tested_version'])
        older = dict(self.old)
        base = {'xrayVersion': newer['xray_online_version'], 'installerRef': newer['xray_installer_ref'],
                'installerSha256': newer['xray_installer_sha256'], 'testedVersion': newer['xray_tested_version']}
        evidence = {'base': base, 'candidate': {'allowRollback': False}}
        for name, value in (('expected', newer), ('candidate', older), ('evidence', evidence)):
            (self.path / name).write_text(json.dumps(value))
        with patch.object(module, 'api', return_value=self.ref), \
             patch.object(module, 'source_file', side_effect=[newer, {}]), \
             patch.object(module, 'exists') as exists:
            with self.assertRaisesRegex(ValueError, 'downgrade'):
                self.call()
            exists.assert_not_called()
        evidence['candidate']['allowRollback'] = True
        (self.path / 'evidence').write_text(json.dumps(evidence))
        with patch.object(module, 'api', return_value=self.ref), \
             patch.object(module, 'source_file', side_effect=[newer, {}]), \
             patch.object(module.prepare_api_release, 'prepare', return_value={'compatibility.json': b'{}', 'xray_shell_versions.json': b'{}'}), \
             patch.object(module.verify_qualification_run, 'verify') as verify, \
             patch.object(module, 'exists') as exists:
            with self.assertRaisesRegex(ValueError, 'downgrade'):
                self.call()
            verify.assert_not_called()
            exists.assert_not_called()


if __name__ == '__main__':
    unittest.main()
