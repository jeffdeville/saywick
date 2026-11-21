#!/usr/bin/env python3
"""Collect Saywick iPhone crash reports without deleting device logs or uploading data."""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
DEVICE = '460DC4EC-BD01-5A2B-81C2-603058255875'
ENV = {**os.environ, 'DEVELOPER_DIR': os.environ.get('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')}


def run(*args):
    return subprocess.check_output(args, env=ENV, text=True, stderr=subprocess.STDOUT, timeout=60)


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix('.tmp')
    temp.write_text(json.dumps(value, indent=2) + '\n')
    temp.replace(path)


def parse_report(path):
    text = path.read_text()
    decoder = json.JSONDecoder()
    header, end = decoder.raw_decode(text.lstrip())
    rest = text.lstrip()[end:].strip()
    return (header, json.loads(rest)) if rest else ({}, header)


def matching_file(item):
    path = Path(item['relativePath'])
    return (not path.is_absolute() and '..' not in path.parts
            and re.match(r'^(LocalVoiceKeyboard(?:Extension)?|Saywick(?:Share|Status)?)-.*\.ips$', path.name)
            and not item.get('resources', {}).get('isDirectory', False))


def symbols(roots):
    result = {}
    for root in roots:
        for path in root.glob('**/*.dSYM/Contents/Resources/DWARF/*'):
            for uuid, arch in re.findall(r'UUID: ([\w-]+) \((\w+)\)', run('xcrun', 'dwarfdump', '--uuid', str(path))):
                result[(uuid.lower(), arch)] = path
    return result


def summarize(path, index):
    header, report = parse_report(path)
    images = report.get('usedImages', [])
    threads = report.get('threads', [])
    thread = next((t for t in threads if t.get('triggered')), None)
    faulting = report.get('faultingThread')
    if thread is None and isinstance(faulting, int) and 0 <= faulting < len(threads):
        thread = threads[faulting]
    frames = (thread or {}).get('frames', [])
    stack, signature, missing = [], [], set()
    for frame in frames[:20]:
        image_index = frame.get('imageIndex')
        image = images[image_index] if isinstance(image_index, int) and 0 <= image_index < len(images) else {}
        name = image.get('name', '?')
        symbol = frame.get('symbol')
        offset = frame.get('imageOffset', 0)
        signature.append([name, symbol or offset])
        display = symbol or f'{name}+{offset}'
        if name.startswith(('LocalVoiceKeyboard', 'Saywick', 'CTranscribe')):
            key = (image.get('uuid', '').lower(), image.get('arch'))
            if key in index:
                display = run('xcrun', 'atos', '-arch', key[1], '-o', str(index[key]),
                              '-l', hex(image['base']), hex(image['base'] + offset)).strip()
            else:
                missing.add(image.get('uuid', 'unknown'))
        stack.append(display)
    kind = report.get('exception', {}).get('type', header.get('bug_type', 'unknown'))
    fingerprint = hashlib.sha256(json.dumps([kind, signature[:8]], sort_keys=True).encode()).hexdigest()[:16]
    return {'incident': report.get('incident', header.get('incident_id')),
            'time': report.get('captureTime', header.get('timestamp')),
            'process': report.get('procName', header.get('app_name')),
            'exception': report.get('exception'), 'termination': report.get('termination'),
            'build': report.get('bundleInfo'), 'fingerprint': fingerprint,
            'stack': stack, 'missingSymbolUUIDs': sorted(missing), 'report': str(path)}


def check(output, device, symbol_roots):
    output.mkdir(parents=True, exist_ok=True)
    state_path = output / 'state.json'
    state = json.loads(state_path.read_text()) if state_path.exists() else {'reports': {}}
    new, errors = [], []
    index = symbols(symbol_roots)
    with tempfile.TemporaryDirectory() as temp:
        listing = Path(temp) / 'files.json'
        run('xcrun', 'devicectl', 'device', 'info', 'files', '--device', device,
            '--domain-type', 'systemCrashLogs', '--filter',
            "Name CONTAINS[c] 'LocalVoiceKeyboard' OR Name CONTAINS[c] 'Saywick'",
            '--json-output', str(listing))
        data = json.loads(listing.read_text())
        # Missing/changed schema is a failure, never an empty successful check.
        for item in data['result']['files']:
            if not matching_file(item):
                continue
            source = item['relativePath']
            try:
                staged = Path(temp) / 'report.ips'
                run('xcrun', 'devicectl', 'device', 'copy', 'from', '--device', device,
                    '--domain-type', 'systemCrashLogs', '--source', source, '--destination', str(staged))
                digest = hashlib.sha256(staged.read_bytes()).hexdigest()
                if digest in state['reports']:
                    continue  # Also deduplicates reports moved into Retired/.
                target = output / 'reports' / (digest + '.ips')
                target.parent.mkdir(exist_ok=True)
                staged.replace(target)
                summary = summarize(target, index)
                save(output / 'reports' / (digest + '.json'), summary)
                state['reports'][digest] = summary
                new.append(summary)
                save(state_path, state)  # A later failed copy must not lose successful work.
            except (OSError, ValueError, KeyError, IndexError, subprocess.SubprocessError) as error:
                errors.append({'report': source, 'error': str(error)})
    return {'status': 'partial' if errors else 'ok', 'checkedAt': dt.datetime.now(dt.timezone.utc).isoformat(),
            'device': device, 'newReports': new, 'knownReports': len(state['reports']), 'errors': errors}


def collect_diagnostics(output, device, group):
    """Collect only bounded diagnostic JSON, never audio, transcripts or preferences."""
    state_path = output / 'diagnostics-state.json'
    state = json.loads(state_path.read_text()) if state_path.exists() else {'seen': []}
    seen = set(state['seen'])
    new = []
    with tempfile.TemporaryDirectory() as temp:
        listing = Path(temp) / 'files.json'
        run('xcrun', 'devicectl', 'device', 'info', 'files', '--device', device,
            '--domain-type', 'appGroupDataContainer', '--domain-identifier', group,
            '--json-output', str(listing))
        for item in json.loads(listing.read_text())['result']['files']:
            path = Path(item['relativePath'])
            if path.parent != Path('Diagnostics') or not re.fullmatch(
                    r'(?:[\w.-]+\.events|metric-[0-9a-f]{24})\.json', path.name):
                continue
            staged = Path(temp) / 'diagnostic.json'
            run('xcrun', 'devicectl', 'device', 'copy', 'from', '--device', device,
                '--domain-type', 'appGroupDataContainer', '--domain-identifier', group,
                '--source', str(path), '--destination', str(staged))
            if staged.stat().st_size > 2_000_000:
                raise ValueError('Diagnostic payload exceeds size limit')
            payload = json.loads(staged.read_text())
            events = payload if path.name.endswith('.events.json') else [payload]
            if not isinstance(events, list) or not all(isinstance(e, dict) for e in events):
                raise ValueError('Unexpected diagnostic schema')
            for event in events:
                digest = hashlib.sha256(json.dumps([path.name, event], sort_keys=True).encode()).hexdigest()
                if digest in seen:
                    continue
                target = output / 'events' / (digest + '.json')
                save(target, {'source': str(path), 'payload': event})
                new.append({'id': digest, 'source': str(path), 'report': str(target)})
                seen.add(digest)
                save(state_path, {'seen': sorted(seen)})
    return new


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', default=DEVICE)
    parser.add_argument('--output', type=Path, default=ROOT / '.local-diagnostics')
    parser.add_argument('--symbols', type=Path, action='append')
    parser.add_argument('--group', default='group.com.yourname.localvoicekeyboard')
    args = parser.parse_args()
    try:
        result = check(args.output, args.device, args.symbols or [ROOT / '.local-diagnostics/builds',
                       ROOT / '.build/DeploymentDerivedData/Build/Products/Release-iphoneos'])
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        result = {'status': 'unavailable', 'checkedAt': dt.datetime.now(dt.timezone.utc).isoformat(),
                  'error': str(error)}
    try:
        result['newDiagnostics'] = collect_diagnostics(args.output, args.device, args.group)
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        result['diagnosticsError'] = str(error)
        if result['status'] == 'ok':
            result['status'] = 'partial'
    save(args.output / 'latest.json', result)
    print(json.dumps(result, indent=2))
    return 0 if result['status'] == 'ok' else 1


if __name__ == '__main__':
    raise SystemExit(main())
