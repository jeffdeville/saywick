#!/usr/bin/env python3
"""Preserve a Release build, dSYMs and source fingerprints before installation."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
from check import ROOT, save, symbols

os.umask(0o077)
products = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / '.build/DeploymentDerivedData/Build/Products/Release-iphoneos'
app = products / 'LocalVoiceKeyboard.app'
if not app.is_dir():
    raise SystemExit(f'Missing app: {app}')
index = symbols([products])
if not index:
    raise SystemExit('No dSYMs: refusing to preserve a build without symbols')
identifier = hashlib.sha256(json.dumps(sorted(index)).encode()).hexdigest()[:20]
output = ROOT / '.local-diagnostics/builds' / identifier
if output.exists():
    raise SystemExit(f'Build already preserved: {output}')
output.mkdir(parents=True)
try:
    shutil.copytree(app, output / app.name)
    for dsym in products.glob('*.dSYM'):
        shutil.copytree(dsym, output / dsym.name)
    save(output / 'symbols.json', [{'uuid': uuid, 'arch': arch} for uuid, arch in sorted(index)])
    # Build-time provenance must come from the passing coverage run, not today's checkout.
    save(output / 'provenance.json', {'products': str(products.resolve()),
        'note': 'Attach the matching passing coverage sources.json and summary.json before deploying.'})
except Exception:
    shutil.rmtree(output)
    raise
print(output)
