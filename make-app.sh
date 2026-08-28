#!/bin/bash
# Builds a real .app bundle. This is not cosmetic: an unbundled binary has no
# bundle identifier, and WebKit's persistent data stores, the Keychain's
# per-app ACLs and menu-bar status items all key off one. Running loose out of
# .build is what leaves claude.ai stuck in a challenge loop — the clearance
# cookie has nowhere durable to live.
set -euo pipefail
CONF="${1:-debug}"
APP="build/Multimodel Tracker.app"
swift build -c "$CONF"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONF/MultimodelTracker" "$APP/Contents/MacOS/MultimodelTracker"
# Alert audio, copied byte-identical — never trimmed, normalised or re-encoded.
mkdir -p "$APP/Contents/Resources/sounds"
cp Resources/sounds/* "$APP/Contents/Resources/sounds/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>MultimodelTracker</string>
  <key>CFBundleIdentifier</key><string>com.devnewb.multimodeltracker</string>
  <key>CFBundleName</key><string>Multimodel Tracker</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>100</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
# Sign with a STABLE identity, selected by SHA-1 hash — never by name (this
# Mac holds two identically-named Apple Development certs, and by-name
# selection aborts as ambiguous). Ad-hoc is the last resort only: every
# ad-hoc rebuild mints a new code identity, which invalidates the keychain
# item ACLs and made macOS demand the login-keychain password on every poll.
SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk '/Developer ID Application/ {print $2; exit}')}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ {print $2; exit}')"
fi
if [[ -n "$SIGN_IDENTITY" ]]; then
  codesign --force --sign "$SIGN_IDENTITY" "$APP"
  echo "signed with: $SIGN_IDENTITY"
else
  codesign --force --sign - "$APP" 2>/dev/null || true
  echo "WARNING: ad-hoc signed — keychain prompts will return after every rebuild"
fi
echo "built: $APP"
