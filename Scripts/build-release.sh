#!/usr/bin/env bash
# End-to-end release: clean → generate → build release → notarize → DMG
#
# Usage:
#   export DEV_ID_APP="Developer ID Application: Your Name (TEAMID)"
#   export NOTARY_PROFILE=NOTARY
#   mise run release

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

echo "==> Cleaning"
tuist clean
rm -rf build .build Derived

echo "==> Generating Xcode project"
tuist generate --no-open

echo "==> Building Release"
tuist build RuEnSync --configuration Release

echo "==> Signing + notarizing + DMG"
bash Scripts/notarize.sh

echo ""
echo "✔ Release complete: build/dist/RuEnSync.dmg"
