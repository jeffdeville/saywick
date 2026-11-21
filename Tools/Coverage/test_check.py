import unittest
from check import ROOT, llvm, merge, summary, xcode

class CoverageTests(unittest.TestCase):
    def test_union_counts_shared_source_only_once(self):
        lines = {}; path = str(ROOT / 'Sources/App/Example.swift')
        xcode(lines, {path: [{'line': 1, 'isExecutable': True, 'executionCount': 0},
                            {'line': 2, 'isExecutable': True, 'executionCount': 1},
                            {'line': 3, 'isExecutable': False}]})
        xcode(lines, {path: [{'line': 1, 'isExecutable': True, 'executionCount': 1}]})
        self.assertEqual(summary(lines, lines), {'covered': 2, 'executable': 2, 'percent': 100})
    def test_llvm_gap_and_column_one_endpoint_are_not_executable(self):
        lines = {}; path = str(ROOT / 'Sources/App/Example.swift')
        llvm(lines, {'data': [{'files': [{'filename': path, 'segments': [
            [10, 4, 1, True, True, False], [12, 1, 0, True, False, True],
            [14, 1, 0, True, True, False], [15, 1, 0, False, False, False]]}]}]})
        self.assertEqual(lines['Sources/App/Example.swift'], {10: True, 11: True, 14: False})
        merge(lines, str(ROOT / 'Tests/Test.swift'), 1, True)
        self.assertEqual(len(lines), 1)

if __name__ == '__main__': unittest.main()
