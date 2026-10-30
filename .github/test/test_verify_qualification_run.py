#!/usr/bin/env python3
import importlib.util
import json
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('qualification', ROOT / '.github/scripts/verify_qualification_run.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class RunVerificationTests(unittest.TestCase):
    def setUp(self):
        self.repo = 'hello-yunshu/Xray_bash_onekey_api'
        self.sha = 'a' * 40
        self.run = {'id': 11, 'head_sha': self.sha, 'path': '.github/workflows/qualify-release.yml',
                    'event': 'workflow_dispatch', 'status': 'completed', 'conclusion': 'success',
                    'run_attempt': 2, 'repository': {'full_name': self.repo}}
        self.jobs = [{'id': 44, 'name': 'qualify / legacy-upgrade (3.2.9)', 'status': 'completed', 'conclusion': 'success'}]
        self.artifacts = [{'name': 'qualification-evidence-11-2', 'expired': False}]
        self.evidence = json.dumps({'baselines': [{'version': '3.2.9', 'scenarios': {'legacy-upgrade':
                       {'runId': 11, 'jobId': 44, 'job': 'qualify / legacy-upgrade (3.2.9)'}}}]}).encode()

    def verify(self):
        def api(path):
            if '/attempts/' in path:
                return {'jobs': self.jobs}
            if '/artifacts?' in path:
                return {'artifacts': self.artifacts}
            return self.run

        def download(args, **kwargs):
            (Path(args[args.index('--dir') + 1]) / 'compatibility.json').write_bytes(self.evidence)

        with patch.object(module, 'api', side_effect=api), patch.object(module.subprocess, 'run', side_effect=download):
            module.verify(self.evidence, self.repo, 11, self.sha, 2)

    def test_exact_run_job_and_artifact(self):
        self.verify()

    def test_wrong_sha_or_untrusted_pr(self):
        self.run['head_sha'] = 'b' * 40
        with self.assertRaisesRegex(ValueError, 'untrusted'):
            self.verify()
        self.run['head_sha'] = self.sha
        self.run['event'] = 'pull_request'
        with self.assertRaisesRegex(ValueError, 'untrusted'):
            self.verify()

    def test_unsuccessful_or_missing_job_and_expired_artifact(self):
        self.jobs[0]['conclusion'] = 'failure'
        with self.assertRaisesRegex(ValueError, 'unsuccessful'):
            self.verify()
        self.jobs[0]['conclusion'] = 'success'
        self.artifacts[0]['expired'] = True
        with self.assertRaisesRegex(ValueError, 'artifact'):
            self.verify()

    def test_wrong_attempt_and_failed_run(self):
        self.run['run_attempt'] = 1
        with self.assertRaisesRegex(ValueError, 'untrusted'):
            self.verify()
        self.run['run_attempt'] = 2
        self.run['conclusion'] = 'failure'
        with self.assertRaisesRegex(ValueError, 'untrusted'):
            self.verify()


if __name__ == '__main__':
    unittest.main()
