#!/bin/zsh
# Builds Lumen.app and (optionally) installs it to ~/Applications.
set -e
cd "$(dirname "$0")"
APP="build/Lumen.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Build arm64 and x86_64 separately, then merge into a universal binary (Apple Silicon + Intel)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
for ARCH in arm64 x86_64; do
  swiftc -O Sources/main.swift -o "$TMP/ClaudeTrafficLight-$ARCH" \
    -framework AppKit -framework ServiceManagement -target "$ARCH-apple-macos13.0"
done
lipo -create -output "$APP/Contents/MacOS/ClaudeTrafficLight" \
  "$TMP/ClaudeTrafficLight-arm64" "$TMP/ClaudeTrafficLight-x86_64"

cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Lumen</string>
  <key>CFBundleDisplayName</key><string>Lumen</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>local.claude.trafficlight</string>
  <key>CFBundleExecutable</key><string>ClaudeTrafficLight</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

xattr -cr "$APP"
codesign --force --sign - "$APP"

if [[ "$1" == "--install" ]]; then
  mkdir -p ~/Applications
  pkill -x ClaudeTrafficLight 2>/dev/null || true
  rm -rf ~/Applications/"Claude Traffic Light.app"   # legacy name before the rename to Lumen
  rm -rf ~/Applications/Lumen.app
  cp -R "$APP" ~/Applications/
  open ~/Applications/Lumen.app
  echo "Installed and started: ~/Applications/Lumen.app"
else
  echo "Built: $APP  (use --install to copy it to ~/Applications and launch)"
fi
