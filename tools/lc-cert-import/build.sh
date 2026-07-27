#!/usr/bin/env bash
#
# Build iPASideCertImport.dylib for iOS.
#
# Needs Xcode's iPhoneOS SDK, so this only runs on macOS - which is why CI builds it on
# a macos runner and commits the result into the engine's vendor directory. iPASide
# itself never compiles it; Windows has no toolchain that can emit an iOS Mach-O dylib.
#
# LiveContainer and all three of its bundled dylibs are arm64-only, so a single slice
# matches the host exactly and a fat binary would just be dead weight.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="${1:-$here/iPASideCertImport.dylib}"

if ! command -v xcrun >/dev/null 2>&1; then
    echo "xcrun not found - this script requires Xcode on macOS" >&2
    exit 1
fi

sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
echo "SDK:    $sdk"
echo "Output: $out"

# -miphoneos-version-min matches LiveContainer's own floor, so the dylib loads on every
# device LiveContainer itself supports.
xcrun --sdk iphoneos clang \
    -arch arm64 \
    -isysroot "$sdk" \
    -miphoneos-version-min=14.0 \
    -dynamiclib \
    -fobjc-arc \
    -framework Foundation \
    -framework Security \
    -install_name "@executable_path/iPASideCertImport.dylib" \
    -Wall -Wextra -Werror \
    -O2 \
    -o "$out" \
    "$here/iPASideCertImport.m"

echo
echo "Built:"
ls -la "$out"
echo
echo "Architectures:"
xcrun lipo -info "$out"
echo
echo "Load commands of interest:"
xcrun otool -l "$out" | grep -A3 -E "LC_ID_DYLIB|LC_BUILD_VERSION" || true
