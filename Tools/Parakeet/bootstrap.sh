#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
revision=93151602c670f0dbf6703b1d87a8822f87581a0b
source_dir="$root/.build/Parakeet/source"
package_dir="$root/.build/Parakeet/SwiftPackage"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export PATH="$root/.build/pause-bench-tools/bin:$PATH"
command -v cmake >/dev/null || { echo 'Install CMake before building Parakeet.' >&2; exit 1; }
mkdir -p "$package_dir/Sources"
if [ ! -d "$source_dir/.git" ]; then
    git clone --no-checkout https://github.com/handy-computer/transcribe.cpp.git "$source_dir"
fi
git -C "$source_dir" fetch origin "$revision" --depth=1
git -C "$source_dir" checkout --detach "$revision"
# Disable device Metal too: runtime backend enumeration initializes it even for
# CPU requests. The keyboard must work with its containing app in background.
python3 "$root/Tools/Parakeet/prepare_build.py" "$source_dir/scripts/ci/build_xcframework.sh"
TRANSCRIBE_XCFRAMEWORK_SLICES='ios-device ios-sim' bash "$source_dir/scripts/ci/build_saywick_xcframework.sh"
cp -R "$source_dir/bindings/swift/Sources/TranscribeCpp" "$package_dir/Sources/"
ditto "$source_dir/bindings/swift/build-apple/TranscribeCpp.xcframework" "$package_dir/TranscribeCpp.xcframework"
cp "$source_dir/bindings/swift/LICENSE" "$source_dir/bindings/swift/THIRD-PARTY-LICENSES.md" "$package_dir/"
cp "$root/Tools/Parakeet/Package.swift" "$package_dir/Package.swift"
echo "$revision" > "$package_dir/REVISION"
