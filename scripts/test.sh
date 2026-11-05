#!/bin/bash
# Birim testleri. VLCKit'in kurulum adı @loader_path/../Frameworks olduğu için test paketine kopyalanır.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/fetch-vlckit.sh >/dev/null
swift build --build-tests
BUNDLE="$(find .build -path '*Debug/KDPlayerTests.xctest' -maxdepth 5 -type d | head -1)"
[[ -n "$BUNDLE" ]] || BUNDLE="$(swift build --show-bin-path)/KDPlayerTests.xctest"
mkdir -p "$BUNDLE/Contents/Frameworks"
rsync -a --delete Vendor/VLCKit.xcframework/macos-arm64_x86_64/VLCKit.framework "$BUNDLE/Contents/Frameworks/"
swift test --skip-build "$@"
