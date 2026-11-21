#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
coverage_dir=".build/Coverage/run-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$coverage_dir"
# Save exact source fingerprints with the reports; only combine runs of these sources.
python3 - "$coverage_dir/sources.json" <<'PY'
import hashlib,json,pathlib,subprocess,sys
root=pathlib.Path('.')
json.dump({'revision':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
 'sources':{str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(root.glob('Sources/**/*.swift'))}},open(sys.argv[1],'w'),indent=2)
package=root/'.build/Parakeet/SwiftPackage'
native={str(p.relative_to(package)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(package.rglob('*')) if p.is_file()}
pathlib.Path(sys.argv[1]).with_name('native.json').write_text(json.dumps(native,indent=2))
PY
swift test --enable-code-coverage
coverage_json="$(swift test --show-codecov-path)"
cp "$coverage_json" "$coverage_dir/core.json"
xcodebuild -project LocalVoiceKeyboard.xcodeproj -scheme LocalVoiceKeyboard \
  -clonedSourcePackagesDirPath .build/SourcePackages -derivedDataPath .build/UITestDerivedData \
  -destination "platform=iOS Simulator,name=${SIMULATOR:-iPhone 17 Pro}" \
  -enableCodeCoverage YES -resultBundlePath "$coverage_dir/app.xcresult" test
python3 -m unittest discover -s Tools/Coverage -p 'test_*.py'
python3 Tools/Coverage/check.py --llvm "$coverage_dir/core.json" --xcresult "$coverage_dir/app.xcresult" --output "$coverage_dir/summary.json"
