import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import check


class DiagnosticsTests(unittest.TestCase):
    def test_filters_unrelated_and_unsafe_paths(self):
        for name in ['../LocalVoiceKeyboard-a.ips', '/LocalVoiceKeyboard-a.ips', 'OtherKeyboard-a.ips']:
            self.assertFalse(check.matching_file({'relativePath': name}))
        self.assertTrue(check.matching_file({'relativePath': 'Retired/LocalVoiceKeyboardExtension-a.ips'}))
        for name in ['SaywickShare-a.ips', 'SaywickStatus-a.ips', 'Saywick-a.ips']:
            self.assertTrue(check.matching_file({'relativePath': name}))

    def test_parse_and_group_without_addresses(self):
        with tempfile.TemporaryDirectory() as temp:
            p = Path(temp) / 'a.ips'
            report = {'exception': {'type': 'EXC_BREAKPOINT'}, 'threads': [{'triggered': True,
                      'frames': [{'imageIndex': 0, 'imageOffset': 17, 'symbol': 'insert'}]}],
                      'usedImages': [{'name': 'LocalVoiceKeyboardExtension', 'base': 100, 'uuid': 'abc', 'arch': 'arm64'}]}
            p.write_text('{}\n' + json.dumps(report))
            first = check.summarize(p, {})
            report['usedImages'][0]['base'] = 900
            p.write_text(json.dumps(report))
            second = check.summarize(p, {})
            self.assertEqual(first['fingerprint'], second['fingerprint'])
            self.assertEqual(first['missingSymbolUUIDs'], ['abc'])
            report['usedImages'][0]['name'] = 'CTranscribe'
            p.write_text(json.dumps(report))
            self.assertEqual(check.summarize(p, {})['missingSymbolUUIDs'], ['abc'])

    def test_incomplete_stack_indices_preserve_report(self):
        with tempfile.TemporaryDirectory() as temp:
            p = Path(temp) / 'a.ips'
            for index in [-1, 99]:
                p.write_text(json.dumps({'faultingThread': index, 'threads': []}))
                self.assertEqual(check.summarize(p, {})['stack'], [])
            p.write_text(json.dumps({'threads': [{'triggered': True, 'frames': [
                {'imageIndex': 99, 'symbol': 'known'}, {'imageIndex': -1}, {}]}]}))
            self.assertEqual(check.summarize(p, {})['stack'], ['known', '?+0', '?+0'])

    def test_repeat_and_retired_reports_deduplicate(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            def fake(*args):
                if 'files' in args:
                    Path(args[args.index('--json-output') + 1]).write_text(json.dumps({'result': {'files': [
                        {'relativePath': 'LocalVoiceKeyboard-a.ips'},
                        {'relativePath': 'Retired/LocalVoiceKeyboard-a.ips'}]}}))
                elif 'copy' in args:
                    Path(args[args.index('--destination') + 1]).write_text('{"incident":"one"}')
                return ''
            with patch.object(check, 'run', side_effect=fake):
                self.assertEqual(len(check.check(root, 'device', [])['newReports']), 1)
                self.assertEqual(len(check.check(root, 'device', [])['newReports']), 0)

    def test_invalid_report_remains_retryable(self):
        with tempfile.TemporaryDirectory() as temp:
            def fake(*args):
                if 'files' in args:
                    Path(args[args.index('--json-output') + 1]).write_text('{"result":{"files":[{"relativePath":"LocalVoiceKeyboard-a.ips"}]}}')
                else:
                    Path(args[args.index('--destination') + 1]).write_text('broken')
                return ''
            with patch.object(check, 'run', side_effect=fake):
                result = check.check(Path(temp), 'device', [])
                self.assertEqual(result['status'], 'partial')
                self.assertEqual(result['knownReports'], 0)

    def test_handled_errors_deduplicate_and_do_not_copy_user_content(self):
        with tempfile.TemporaryDirectory() as temp:
            copied = []
            def fake(*args):
                if 'files' in args:
                    Path(args[args.index('--json-output') + 1]).write_text(json.dumps({'result': {'files': [
                        {'relativePath': 'Diagnostics/com.saywick.events.json'},
                        {'relativePath': 'History/transcript.json'},
                        {'relativePath': 'Diagnostics/../secrets.events.json'}]}}))
                else:
                    copied.append(args[args.index('--source') + 1])
                    Path(args[args.index('--destination') + 1]).write_text('[{"operation":"audio.capture","code":1}]')
                return ''
            with patch.object(check, 'run', side_effect=fake):
                self.assertEqual(len(check.collect_diagnostics(Path(temp), 'device', 'group')), 1)
                self.assertEqual(check.collect_diagnostics(Path(temp), 'device', 'group'), [])
            self.assertEqual(copied, ['Diagnostics/com.saywick.events.json'] * 2)

    def test_missing_listing_is_not_success(self):
        with tempfile.TemporaryDirectory() as temp:
            def fake(*args):
                Path(args[args.index('--json-output') + 1]).write_text('{}')
                return ''
            with patch.object(check, 'run', side_effect=fake), self.assertRaises(KeyError):
                check.check(Path(temp), 'device', [])

if __name__ == '__main__':
    unittest.main()
