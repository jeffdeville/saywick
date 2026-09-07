"""Apply explicit iOS packaging choices to the pinned upstream build script."""
from pathlib import Path
import sys

source = Path(sys.argv[1])
text = source.read_text()
changes = {
    'build_arch ios-device iOS iphoneos arm64 ON':
        'build_arch ios-device iOS iphoneos arm64 OFF',
    '    local extra=()':
        '    local extra=()\n'
        '    if [[ "$arch" == "arm64" ]]; then\n'
        '        extra+=(-DGGML_CPU_ARM_ARCH=armv8.2-a+dotprod -DGGML_BLAS=ON)\n'
        '    fi',
    'IOS_MIN="${IOS_MIN_OS_VERSION:-16.0}"':
        'IOS_MIN="${IOS_MIN_OS_VERSION:-26.0}"',
}
for old, new in changes.items():
    if text.count(old) != 1:
        raise RuntimeError(f"Upstream packaging changed: expected one {old!r}")
    text = text.replace(old, new)
source.with_name("build_saywick_xcframework.sh").write_text(text)

# Upstream forces the separate ggml BLAS backend off. Preserve its default,
# but allow the explicit Apple-only build flag above to take effect.
cmake = source.parents[2] / "CMakeLists.txt"
text = cmake.read_text()
old = 'set(GGML_BLAS OFF CACHE BOOL "" FORCE)'
new = 'set(GGML_BLAS OFF CACHE BOOL "")'
if text.count(old) == 1:
    cmake.write_text(text.replace(old, new))
elif text.count(new) != 1:
    raise RuntimeError("Upstream GGML_BLAS configuration changed")
