#!/bin/zsh
# Assemble and sign "DSH Reflex Helper.app".
# usage: bundle-app.sh <reflex-helper> <reflex-axcheck> <out.app> [version]
set -euo pipefail
HELPER_EXE="$1"
AXCHECK_EXE="$2"
APP_PATH="$3"
VERSION="${4:-0.1.0}"
BUNDLE_ID="dev.dshreflex.helper"
IDENTITY="${REFLEX_CODESIGN_IDENTITY:-DSH Reflex Local Code Signing}"
BUILD_NUMBER="${REFLEX_BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"

# Assemble in a private temp directory and move it into place at the end, so a concurrent run never
# sees (or signs) a half-built bundle.
FINAL_PATH="$APP_PATH"
APP_PATH="$(dirname "$FINAL_PATH")/.$(basename "$FINAL_PATH").$$.tmp"
rm -rf "$APP_PATH"
trap 'rm -rf "$APP_PATH"' EXIT
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$HELPER_EXE" "$APP_PATH/Contents/MacOS/reflex-helper"
cp "$AXCHECK_EXE" "$APP_PATH/Contents/MacOS/reflex-axcheck"
mkdir -p "$APP_PATH/Contents/Resources/ThirdParty"
cp "${0:A:h}/../swift/Sources/ReflexVirtualDisplayBridge/LICENSE.txt" "$APP_PATH/Contents/Resources/ThirdParty/DisplayLoom-LICENSE.txt"
cat > "$APP_PATH/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleName</key><string>DSH Reflex Helper</string>
<key>CFBundleDisplayName</key><string>DSH Reflex Helper</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleExecutable</key><string>reflex-helper</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSAccessibilityUsageDescription</key><string>DSH Reflex reads the UI of apps you configure (for example Teams live captions) to trigger your DSH rules.</string>
</dict></plist>
PLIST

SIGN="-"
if security find-identity -v -p codesigning | grep -Fq "\"$IDENTITY\""; then
  SIGN="$IDENTITY"
else
  echo "warning: code-signing identity \"$IDENTITY\" not found; signing ad-hoc." >&2
  echo "         Accessibility must be re-granted after every rebuild. Run scripts/setup-local-signing.sh once." >&2
fi
codesign --force --timestamp=none --identifier "dev.dshreflex.axcheck" --sign "$SIGN" "$APP_PATH/Contents/MacOS/reflex-axcheck"
codesign --force --timestamp=none --identifier "$BUNDLE_ID" --sign "$SIGN" "$APP_PATH"
codesign --verify --strict "$APP_PATH"
rm -rf "$FINAL_PATH"
mv "$APP_PATH" "$FINAL_PATH"
trap - EXIT
echo "signed $FINAL_PATH with ${SIGN/#-/ad-hoc}"
