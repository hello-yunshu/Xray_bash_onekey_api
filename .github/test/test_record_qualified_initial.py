#!/usr/bin/env python3
import importlib.util
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / '.github/scripts'))
spec = importlib.util.spec_from_file_location('record_initial', ROOT / '.github/scripts/record_qualified_initial.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class RecordTests(unittest.TestCase):
    def test_new_qualified_tuple_is_preferred_without_losing_history(self):
        old = dict(xrayVersion='26.3.27', installerRef='a' * 40, installerSha256='b' * 64)
        doc = dict(trustedInitials=[old], baselines=[{'version': '3.2.9', 'initial': old}])
        metadata = dict(xray_online_version='26.10.31', xray_installer_ref='c' * 40, xray_installer_sha256='d' * 64)
        result = module.record(doc, metadata)
        self.assertEqual(len(result['trustedInitials']), 2)
        self.assertEqual(result['trustedInitials'][0]['xrayVersion'], '26.10.31')
        self.assertEqual(result['baselines'], doc['baselines'])
        self.assertEqual(len(doc['trustedInitials']), 1)
        self.assertEqual(module.record(result, metadata), result)

    def test_invalid_tuple_is_never_recorded(self):
        with self.assertRaises(ValueError):
            module.record({}, dict(xray_online_version='latest', xray_installer_ref='c' * 40, xray_installer_sha256='d' * 64))

    def test_publisher_records_only_after_release_verification(self):
        source = (ROOT / '.github/workflows/promote-qualified-release.yml').read_text()
        self.assertLess(source.index('publish_api_release.py'), source.index('record_qualified_initial.py'))
        self.assertLess(source.index('cmp "$tmp/staged.sorted"'), source.index('record_qualified_initial.py'))
        self.assertIn('git add xray_shell_versions.json compatibility-baselines.json', source)


if __name__ == '__main__':
    unittest.main()
