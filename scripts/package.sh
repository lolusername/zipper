#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/build/Zipper.app"
if [[ -L build ]]; then
    printf 'Refusing a symlinked build directory.\n' >&2
    exit 1
fi
mkdir -p build
LOCK="$PWD/build/.package-lock"
if ! mkdir "$LOCK" 2>/dev/null; then
    printf 'Packaging is already locked at %s. If a previous run was killed, confirm no package process remains before removing that empty lock directory.\n' "$LOCK" >&2
    exit 1
fi
STAGING=''
cleanup() {
    local result=$?
    trap - EXIT HUP INT TERM
    if [[ -n "$STAGING" ]]; then rm -rf "$STAGING"; fi
    rmdir "$LOCK" || true
    exit "$result"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
STAGING=$(mktemp -d "$PWD/build/.package-XXXXXX")
swiftc scripts/publish-app.swift -o "$STAGING/publish-app"
"$STAGING/publish-app" check "$APP"
swift build -c release
STAGED_APP="$STAGING/Zipper.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp .build/release/Zipper "$STAGED_APP/Contents/MacOS/Zipper"
cat > "$STAGED_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleExecutable</key><string>Zipper</string>
<key>CFBundleIdentifier</key><string>studio.zipper.handoff</string>
<key>CFBundleName</key><string>Zipper</string>
<key>CFBundleDisplayName</key><string>Zipper</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.3</string>
<key>CFBundleVersion</key><string>4</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleIconFile</key><string>Zipper</string>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026. Zipper contributors.</string>
</dict></plist>
PLIST
swift scripts/make-icon.swift "$STAGED_APP/Contents/Resources"
codesign --force --sign - --options runtime "$STAGED_APP"
codesign --verify --strict --verbose=2 "$STAGED_APP"
# Publication rechecks the running executable, then uses an atomic filesystem
# operation. A failure leaves the previous bundle at its original path.
"$STAGING/publish-app" publish "$STAGED_APP" "$APP"
printf 'Built app: %s\n' "$APP"
