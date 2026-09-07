#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP="$PWD/build/Zipper.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Zipper "$APP/Contents/MacOS/Zipper"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleExecutable</key><string>Zipper</string>
<key>CFBundleIdentifier</key><string>studio.zipper.handoff</string>
<key>CFBundleName</key><string>Zipper</string>
<key>CFBundleDisplayName</key><string>Zipper</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleIconFile</key><string>Zipper</string>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026. Zipper contributors.</string>
</dict></plist>
PLIST
swift scripts/make-icon.swift "$APP/Contents/Resources"
codesign --force --sign - --options runtime "$APP"
codesign --verify --strict --verbose=2 "$APP"
printf 'Built app: %s\n' "$APP"
