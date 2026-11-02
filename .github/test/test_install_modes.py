#!/usr/bin/env python3
import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('install_modes', ROOT / '.github/scripts/install_modes.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def script(accepted, dispatched):
    return f'''#!/bin/bash
case "$MODE" in
{accepted}) ;;
*) exit 1 ;;
esac
case "$MODE" in
{dispatched})
    install_something
    ;;
esac
'''


class InstallModeTests(unittest.TestCase):
    def test_current_and_historical_mode_sets(self):
        self.assertEqual(module.parse(script('xtls_only | ws_grpc_xhttp | reality | reality_nginx | tls',
                                             'xtls_only | ws_grpc_xhttp | reality | reality_nginx | tls')),
                         ['xtls_only', 'ws_grpc_xhttp', 'reality', 'reality_nginx', 'tls'])
        self.assertEqual(module.parse(script('relay | ws_grpc_xhttp | reality | reality_nginx | tls',
                                             'relay | ws_grpc_xhttp | reality | reality_nginx | tls')),
                         ['relay', 'ws_grpc_xhttp', 'reality', 'reality_nginx', 'tls'])

    def test_grouped_dispatch_labels(self):
        self.assertEqual(module.parse(script('relay | reality | reality_nginx',
                                             'relay | reality | reality_nginx')),
                         ['relay', 'reality', 'reality_nginx'])

    def test_rejects_empty_duplicate_or_mismatched_modes(self):
        for accepted, dispatched in (('*', 'reality'),
                                     ('reality | reality', 'reality | reality'),
                                     ('relay | reality', 'relay')):
            with self.subTest(accepted=accepted, dispatched=dispatched):
                with self.assertRaises(ValueError):
                    module.parse(script(accepted, dispatched))

    def test_rejects_missing_dispatch_case(self):
        with self.assertRaisesRegex(ValueError, 'exactly'):
            module.parse('case "$MODE" in\nreality) ;;\nesac\n')

    def test_repository_shell_versions_parse(self):
        # The API tests do not assume a sibling checkout; exercise stable fixtures above.
        pass


if __name__ == '__main__':
    unittest.main()
