#!/usr/bin/env python3
import datetime as dt
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / '.github/scripts' / (name + '.py'))
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


health = module('check_xray_download_health')
scheduler = module('dispatch_upstream_qualification')


class HealthTests(unittest.TestCase):
    def setUp(self):
        import hashlib
        self.metadata = dict(xray_online_version='26.10.31', xray_tested_version='25.12.8',
                             xray_installer_ref='a' * 40, xray_installer_sha256=hashlib.sha256(b'installer').hexdigest())

    def release(self, path):
        return {'tag_name': path.split('/')[-1], 'assets': [
            {'name': f'Xray-linux-{arch}{suffix}'} for arch in health.ARCHES for suffix in ('.zip', '.zip.dgst')]}

    def test_checks_both_versions_and_architectures_without_metadata_write(self):
        before = dict(self.metadata)
        urls = []
        with patch.object(health.subprocess, 'check_output', return_value=b'installer'):
            self.assertEqual(health.check(self.metadata, self.release, urls.append), [])
        self.assertEqual(len(urls), 8)
        self.assertEqual(self.metadata, before)

    def test_deleted_release_does_not_skip_fallback(self):
        checked = []

        def fetch(path):
            checked.append(path)
            if path.endswith('v26.10.31'):
                raise subprocess.CalledProcessError(1, 'gh')
            return self.release(path)
        with patch.object(health.subprocess, 'check_output', return_value=b'installer'):
            errors = health.check(self.metadata, fetch, lambda url: None)
        self.assertEqual(len(errors), 1)
        self.assertEqual(len(checked), 2)
        self.assertIn('26.10.31', errors[0])

    def test_missing_asset_download_failure_and_installer_mismatch(self):
        def bad_release(path):
            return dict(self.release(path), assets=[])
        with patch.object(health.subprocess, 'check_output', return_value=b'wrong'):
            self.assertEqual(len(health.check(self.metadata, bad_release, lambda url: None)), 3)
        def bad_head(url):
            raise subprocess.CalledProcessError(22, 'curl')
        with patch.object(health.subprocess, 'check_output', return_value=b'installer'):
            self.assertEqual(len(health.check(self.metadata, self.release, bad_head)), 2)


class SchedulerTests(unittest.TestCase):
    now = dt.datetime(2026, 11, 1, tzinfo=dt.timezone.utc)

    def record(self, age=1, status='completed', conclusion='failure', key='key'):
        return dict(display_title=key, event='workflow_dispatch', head_branch='main', status=status,
                    conclusion=conclusion, created_at=(self.now-dt.timedelta(hours=age)).isoformat())

    def test_new_candidate_and_daily_retry(self):
        self.assertTrue(scheduler.decision([], 'key', self.now)[0])
        self.assertTrue(scheduler.decision([self.record(age=25)], 'key', self.now)[0])
        self.assertTrue(scheduler.decision([self.record(key='old')], 'key', self.now)[0])

    def test_active_and_recent_runs_are_not_repeated(self):
        for status in ('queued', 'in_progress', 'waiting'):
            self.assertFalse(scheduler.decision([self.record(age=25, status=status)], 'key', self.now)[0])
        for conclusion in ('success', 'failure', 'cancelled'):
            self.assertFalse(scheduler.decision([self.record(conclusion=conclusion)], 'key', self.now)[0])

    def test_latest_run_controls_cooldown(self):
        self.assertFalse(scheduler.decision([self.record(age=50), self.record(age=2)], 'key', self.now)[0])

    def test_core_change_also_uses_qualified_installer(self):
        env = dict(GITHUB_REPOSITORY='owner/repo', BASE_VERSION='26.10.29', BASE_REF='a', BASE_SHA='b',
                   CANDIDATE_VERSION='26.10.31', CANDIDATE_REF='c', CANDIDATE_SHA='d')
        with patch.dict(os.environ, env), patch.object(scheduler, 'dispatch') as dispatch:
            scheduler.main()
        self.assertEqual(dispatch.call_count, 2)
        self.assertEqual(dispatch.call_args_list[0].args[0]['CANDIDATE_REF'], 'a')
        self.assertEqual(dispatch.call_args_list[1].args[0]['CANDIDATE_REF'], 'c')

    def test_dispatch_arguments_and_persisted_key_prevent_repeat(self):
        values = dict(BASE_VERSION='26.10.29', BASE_REF='a' * 40, BASE_SHA='b' * 64,
                      CANDIDATE_VERSION='26.10.31', CANDIDATE_REF='c' * 40, CANDIDATE_SHA='d' * 64)
        old = Path.cwd()
        os.chdir(ROOT)
        try:
            with patch.object(scheduler.subprocess, 'check_output', return_value='[{"workflow_runs": []}]'), \
                 patch.object(scheduler.subprocess, 'run') as run:
                scheduler.dispatch(values, 'owner/repo')
            args = run.call_args.args[0]
            self.assertIn('candidate_version=26.10.31', args)
            key = args[-1].split('=', 1)[1]
            record = self.record(status='in_progress', key=key)
            with patch.object(scheduler.subprocess, 'check_output', return_value=json.dumps([{'workflow_runs': [record]}])), \
                 patch.object(scheduler.subprocess, 'run') as run:
                scheduler.dispatch(values, 'owner/repo')
                run.assert_not_called()
            with patch.object(scheduler.subprocess, 'check_output', side_effect=subprocess.CalledProcessError(1, 'gh')), \
                 patch.object(scheduler.subprocess, 'run') as run:
                with self.assertRaises(subprocess.CalledProcessError):
                    scheduler.dispatch(values, 'owner/repo')
                run.assert_not_called()
        finally:
            os.chdir(old)

    def test_workflow_health_failure_triggers_discovery_and_preserves_gate(self):
        watch = (ROOT / '.github/workflows/watch-upstreams.yml').read_text()
        health_workflow = (ROOT / '.github/workflows/check-xray-downloads.yml').read_text()
        self.assertIn("cron: '17 * * * *'", health_workflow)
        self.assertIn("cron: '23 */6 * * *'", watch)
        self.assertIn("github.event.workflow_run.conclusion == 'failure'", watch)
        self.assertNotIn('git push', watch)
        self.assertIn('dispatch_upstream_qualification.py', watch)


if __name__ == '__main__':
    unittest.main()
