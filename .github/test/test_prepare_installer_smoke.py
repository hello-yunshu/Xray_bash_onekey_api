#!/usr/bin/env python3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / '.github/scripts'))
import prepare_installer_smoke as module


class InstallerSmokePreparationTests(unittest.TestCase):
    def test_version_reader_consumes_remaining_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            source, target = Path(tmp) / 'source', Path(tmp) / 'target'
            source.write_text(module.OLD)
            self.assertTrue(module.prepare(source, target))
            producer = "printf 'Xray 26.10.29\\n'; seq 1 100000"
            result = subprocess.run(['bash', '-o', 'pipefail', '-c',
                                     f'({producer}) | {target.read_text()}'],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, '26.10.29\n')

    def test_unknown_harness_is_unchanged_and_ambiguous_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            source, target = Path(tmp) / 'source', Path(tmp) / 'target'
            source.write_text('echo unchanged\n')
            self.assertFalse(module.prepare(source, target))
            self.assertEqual(target.read_text(), source.read_text())
            source.write_text(module.OLD + '\n' + module.OLD)
            with self.assertRaisesRegex(ValueError, 'ambiguous'):
                module.prepare(source, target)


if __name__ == '__main__':
    unittest.main()
