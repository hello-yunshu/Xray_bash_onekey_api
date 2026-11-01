#!/usr/bin/env python3
import importlib.util
import unittest
from pathlib import Path
from unittest.mock import Mock

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('resolve_publish', ROOT / '.github/scripts/resolve_qualification_for_publish.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ResolveTests(unittest.TestCase):
    def setUp(self):
        self.repo = 'owner/repo'
        self.run = dict(id=123, event='workflow_dispatch', head_branch='main', head_sha='a' * 40,
            path='.github/workflows/qualify-release.yml', repository={'full_name': self.repo},
            head_repository={'full_name': self.repo}, status='completed', conclusion='success',
            run_attempt=1, created_at='2026-11-01T08:00:00Z')

    def test_waits_for_qualification_to_complete_before_authorizing_publish(self):
        fetch = Mock(side_effect=[dict(self.run, status='in_progress', conclusion=None), self.run])
        pause = Mock()
        resolved = module.resolve(self.repo, 123, 'a' * 40, fetch, pause)
        self.assertEqual(resolved['attempt'], 1)
        pause.assert_called_once_with(5)

    def test_forged_stale_failed_and_pr_runs_rejected(self):
        for field, value in [('head_sha', 'b' * 40), ('head_branch', 'feature'), ('event', 'pull_request'),
                             ('path', '.github/workflows/other.yml'), ('conclusion', 'failure'),
                             ('head_repository', {'full_name': 'fork/repo'}), ('run_attempt', False)]:
            with self.subTest(field=field), self.assertRaises(ValueError):
                module.resolve(self.repo, 123, 'a' * 40, lambda path: dict(self.run, **{field:value}), lambda seconds: None)

    def test_nonterminating_qualification_times_out_without_publication(self):
        with self.assertRaisesRegex(ValueError, 'timeout'):
            module.resolve(self.repo, 123, 'a' * 40, lambda path: dict(self.run, status='in_progress'), lambda seconds: None)

    def test_explicit_dispatch_is_the_single_automatic_publish_path(self):
        qualifier = (ROOT / '.github/workflows/qualify-release.yml').read_text()
        publisher = (ROOT / '.github/workflows/promote-qualified-release.yml').read_text()
        self.assertIn('needs: evidence', qualifier)
        self.assertIn('gh workflow run promote-qualified-release.yml --ref main', qualifier)
        self.assertIn('qualification_run="$GITHUB_RUN_ID"', qualifier)
        self.assertNotIn('  workflow_run:', publisher)
        self.assertIn('resolve_qualification_for_publish.py', publisher)


if __name__ == '__main__':
    unittest.main()
