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
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>MultimodelTracker</string>
  <key>CFBundleIdentifier</key><string>com.devnewb.multimodeltracker</string>
  <key>CFBundleName</key><string>Multimodel Tracker</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
# Ad-hoc sign so the bundle has a stable identity for Keychain ACLs.
codesign --force --sign - "$APP" 2>/dev/null || true
echo "built: $APP"
