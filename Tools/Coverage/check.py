#!/usr/bin/env python3
"""Union executable source lines across LLVM and Xcode; never average percentages."""
import argparse
import json
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[2]
FOCUS = {"Sources/VoiceKeyboardCore/DictationSession.swift", "Sources/App/DictationController.swift",
         "Sources/KeyboardExtension/KeyboardViewController.swift", "Sources/App/AppModel.swift",
         "Sources/Shared/SharedContainerStore.swift", "Sources/VoiceKeyboardCore/KeyboardRecordingState.swift"}

def merge(lines, filename, line, hit):
    path = pathlib.Path(filename).resolve()
    if not path.is_relative_to(ROOT / 'Sources') or path.suffix != '.swift':
        return
    key = str(path.relative_to(ROOT))
    lines.setdefault(key, {})[line] = lines.get(key, {}).get(line, False) or hit

def llvm(lines, report):
    for data in report['data']:
        for f in data['files']:
            segments = f['segments']
            for a, b in zip(segments, segments[1:]):
                if not a[3] or (len(a) > 5 and a[5]):
                    continue
                end = b[0] - (b[1] == 1)
                for line in range(a[0], end + 1):
                    merge(lines, f['filename'], line, a[2] > 0)

def xcode(lines, report):
    for filename, values in report.items():
        for value in values:
            if value.get('isExecutable'):
                merge(lines, filename, value['line'], value.get('executionCount', 0) > 0)

def summary(lines, names):
    covered = sum(sum(lines.get(name, {}).values()) for name in names)
    total = sum(len(lines.get(name, {})) for name in names)
    return {'covered': covered, 'executable': total, 'percent': covered * 100 / total if total else 0}

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--llvm', action='append', default=[])
    parser.add_argument('--xcresult', action='append', default=[])
    parser.add_argument('--output', required=True)
    parser.add_argument('--minimum', type=float, default=70)
    args = parser.parse_args()
    lines = {}
    for path in args.llvm:
        llvm(lines, json.loads(pathlib.Path(path).read_text()))
    for path in args.xcresult:
        raw = subprocess.check_output(['xcrun', 'xccov', 'view', '--archive', '--json', path])
        xcode(lines, json.loads(raw))
    expected = {str(p.relative_to(ROOT)) for p in (ROOT / 'Sources').rglob('*.swift')}
    # ActivityAttributes contains only stored-property declarations; synthesized
    # Codable/Hashable code has no source executable lines in Xcode's archive.
    declarations_only = {"Sources/Shared/SaywickActivityAttributes.swift"}
    import re
    zero_line = {name for name in declarations_only if not re.search(r"\b(func|init|deinit|subscript)\b|=", (ROOT / name).read_text())}
    missing = sorted(expected - lines.keys() - zero_line)
    report = {'overall': summary(lines, expected), 'refactor': summary(lines, FOCUS), 'missing': missing, 'declarations_only': sorted(zero_line),
              'files': {name: summary(lines, [name]) for name in sorted(expected)}}
    pathlib.Path(args.output).write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({k: report[k] for k in ('overall', 'refactor', 'missing')}, indent=2))
    if missing or any(report[k]['percent'] < args.minimum for k in ('overall', 'refactor')):
        raise SystemExit(1)

if __name__ == '__main__':
    main()
