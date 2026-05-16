#!/usr/bin/env bash
# Sign + notarize + staple the built RuEnSync.app, then produce a DMG.
#
# Prerequisites (one-time):
#   1. Have a "Developer ID Application" certificate in your login keychain.
#      Set DEV_ID_APP to its common name, e.g.
#        export DEV_ID_APP="Developer ID Application: Your Name (TEAMID)"
#   2. Create a notarytool keychain profile once:
#        xcrun notarytool store-credentials NOTARY \
#          --apple-id you@example.com \
#          --team-id TEAMID \
#          --password <app-specific-password>
#      Then export NOTARY_PROFILE=NOTARY (or whatever you named it).
#
# Run:
#   mise run notarize        # (after mise run build:release)

set -euo pipefail

: "${DEV_ID_APP:?must export DEV_ID_APP, e.g. 'Developer ID Application: ... (TEAMID)'}"
: "${NOTARY_PROFILE:?must export NOTARY_PROFILE (the name passed to notarytool store-credentials)}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="${ROOT}/build/dist"
DMG_PATH="${DIST_DIR}/RuEnSync.dmg"
ZIP_PATH="${DIST_DIR}/RuEnSync.zip"

# Tuist puts the .app in the system DerivedData by default. Find the most
# recently modified Release build matching our scheme.
APP_PATH="$(find "${HOME}/Library/Developer/Xcode/DerivedData" \
  -name "RuEnSync.app" -path "*/Release/*" -type d 2>/dev/null \
  | xargs -I {} stat -f "%m %N" {} \
  | sort -rn \
  | head -1 \
  | awk '{print $2}')"

if [[ -z "${APP_PATH}" || ! -d "${APP_PATH}" ]]; then
  echo "❌ RuEnSync.app not found — run 'mise run build:release' first" >&2
  exit 1
fi

echo "→ Using app at ${APP_PATH}"

mkdir -p "${DIST_DIR}"

# --- 1. Codesign with hardened runtime + secure timestamp ---------------------
echo "→ Signing ${APP_PATH}"
codesign --force --options runtime --timestamp --deep \
  --sign "${DEV_ID_APP}" \
  --entitlements "${ROOT}/RuEnSync/RuEnSync.entitlements" \
  "${APP_PATH}"

codesign --verify --strict --verbose=2 "${APP_PATH}"

# --- 2. Notarize --------------------------------------------------------------
echo "→ Zipping for notarization"
ditto -c -k --keepParent "${APP_PATH}" "${ZIP_PATH}"

echo "→ Submitting to notary service (this can take a few minutes)"
xcrun notarytool submit "${ZIP_PATH}" \
  --keychain-profile "${NOTARY_PROFILE}" \
  --wait

# --- 3. Staple ----------------------------------------------------------------
echo "→ Stapling ticket"
xcrun stapler staple "${APP_PATH}"
xcrun stapler validate "${APP_PATH}"

# --- 4. DMG -------------------------------------------------------------------
echo "→ Building DMG at ${DMG_PATH}"
rm -f "${DMG_PATH}"
hdiutil create \
  -volname "RuEnSync" \
  -srcfolder "${APP_PATH}" \
  -ov \
  -format UDZO \
  "${DMG_PATH}"

# Sign the DMG itself so download warnings stay quiet.
codesign --force --sign "${DEV_ID_APP}" "${DMG_PATH}"

echo ""
echo "✔ Done."
echo "  App: ${APP_PATH}"
echo "  DMG: ${DMG_PATH}"
echo ""
echo "Verify Gatekeeper acceptance:"
echo "  spctl --assess --type execute --verbose \"${APP_PATH}\""
