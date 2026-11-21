#!/usr/bin/env python3
"""Reject release archives with wrong versions or missing/mismatched crash symbols."""
import argparse
import os
from pathlib import Path
import plistlib
import re
import subprocess


def uuids(path):
    env = {**os.environ, 'DEVELOPER_DIR': '/Applications/Xcode.app/Contents/Developer'}
    text = subprocess.check_output(['xcrun', 'dwarfdump', '--uuid', str(path)], env=env, text=True)
    return set(re.findall(r'UUID: ([\w-]+) \((\w+)\)', text))


def verify(archive, version, build):
    app = archive / 'Products/Applications/LocalVoiceKeyboard.app'
    bundles = [app, *sorted((app / 'PlugIns').glob('*.appex'))]
    extension_points = set()
    for plugin in bundles[1:]:
        with (plugin / 'Info.plist').open('rb') as file:
            extension_points.add(plistlib.load(file)['NSExtension']['NSExtensionPointIdentifier'])
    assert len(bundles) == 3 and extension_points == {
        'com.apple.keyboard-service', 'com.apple.widgetkit-extension'
    }, 'Expected keyboard and status extensions'
    for bundle in bundles:
        with (bundle / 'Info.plist').open('rb') as file:
            info = plistlib.load(file)
        assert info['CFBundleVersion'] == build, f'{bundle.name}: wrong build number'
        assert info['CFBundleShortVersionString'] == version, f'{bundle.name}: wrong version'
        binary = bundle / info['CFBundleExecutable']
        symbols = archive / 'dSYMs' / (bundle.name + '.dSYM')
        assert symbols.is_dir(), f'Missing symbols: {bundle.name}'
        assert uuids(binary) == uuids(symbols) != set(), f'Mismatched symbols: {bundle.name}'
    native = app / 'Frameworks/CTranscribe.framework'
    assert uuids(native / 'CTranscribe') == uuids(archive / 'dSYMs/CTranscribe.framework.dSYM') != set(), 'Missing/mismatched native symbols'
    with (native / 'PrivacyInfo.xcprivacy').open('rb') as file:
        privacy = plistlib.load(file)
    assert privacy['NSPrivacyTracking'] is False
    assert privacy['NSPrivacyAccessedAPITypes'], 'Missing native required-reason declaration'
    print(f'Verified {version} ({build}): app + 2 extensions, matching Swift/native dSYMs, native privacy manifest')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    parser.add_argument('--version', required=True)
    parser.add_argument('--build', required=True)
    args = parser.parse_args()
    verify(args.archive, args.version, args.build)
