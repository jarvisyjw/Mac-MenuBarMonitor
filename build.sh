#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="build/MenuBarMonitor.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
mkdir -p .module-cache
swiftc -target "$(uname -m)-apple-macos14.0" -module-cache-path ./.module-cache -O \
  -o "$APP/Contents/MacOS/MenuBarMonitor" Sources/main.swift -framework Cocoa
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MenuBarMonitor</string>
  <key>CFBundleIdentifier</key><string>local.menubarmonitor</string>
  <key>CFBundleExecutable</key><string>MenuBarMonitor</string>
  <key>CFBundleIconFile</key><string>AppIcon.icns</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built: $PWD/$APP"
