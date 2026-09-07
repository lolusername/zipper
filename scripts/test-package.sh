#!/bin/bash
# Packaging fault tests use disposable applications and stub build/sign tools.
# The real build/Zipper.app is never read, replaced, launched, or signed.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/zipper-package-tests.XXXXXX")
FIXTURE="$TEST_ROOT/fixture repo"
stop_fixture_process() {
    if [[ -f "$TEST_ROOT/running-pid" ]]; then
        local pid
        pid=$(cat "$TEST_ROOT/running-pid")
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        rm "$TEST_ROOT/running-pid"
    fi
}
cleanup() {
    local result=$?
    trap - EXIT
    stop_fixture_process
    rm -rf "$TEST_ROOT"
    exit "$result"
}
trap cleanup EXIT
swiftc scripts/publish-app.swift -o "$TEST_ROOT/real-publish-app"
printf 'import Darwin\nsleep(60)\n' > "$TEST_ROOT/sleep.swift"
TEMPLATE="$TEST_ROOT/template/Zipper.app"
mkdir -p "$TEMPLATE/Contents/MacOS" "$TEMPLATE/Contents/Resources"
swiftc "$TEST_ROOT/sleep.swift" -o "$TEMPLATE/Contents/MacOS/Zipper"
cat > "$TEMPLATE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Zipper</string>
<key>CFBundleIdentifier</key><string>studio.zipper.packaging-test-fixture</string>
<key>CFBundleName</key><string>Zipper Packaging Test Fixture</string>
<key>CFBundleDisplayName</key><string>Zipper Packaging Test Fixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
printf 'old icon fixture\n' > "$TEMPLATE/Contents/Resources/Zipper.icns"
# Never transplant Apple platform executables or invent the old bundle signature:
# the process-guard tests execute this real, uniquely named, signed fixture.
/usr/bin/codesign --force --sign - "$TEMPLATE"
/usr/bin/codesign --verify --strict "$TEMPLATE"
mkdir -p "$TEST_ROOT/bin"
cat > "$TEST_ROOT/bin/swiftc" <<'STUB'
#!/bin/bash
set -euo pipefail
[[ ${FAIL_STEP:-} != compiler ]] || exit 41
cp "$TEST_ROOT/real-publish-app" "$3"
STUB
cat > "$TEST_ROOT/bin/swift" <<'STUB'
#!/bin/bash
set -euo pipefail
if [[ $1 == build ]]; then
    touch "$TEST_ROOT/build-started"
    [[ ${FAIL_STEP:-} != build ]] || exit 42
    mkdir -p .build/release
    if [[ ${FAIL_STEP:-} != missing_binary ]]; then
        printf 'new executable\n' > .build/release/Zipper
        chmod +x .build/release/Zipper
    fi
else
    [[ ${FAIL_STEP:-} != icon ]] || exit 43
    printf 'new icon\n' > "$2/Zipper.icns"
fi
STUB
cat > "$TEST_ROOT/bin/codesign" <<'STUB'
#!/bin/bash
set -euo pipefail
app="${!#}"
if [[ $1 == --force ]]; then
    [[ ${FAIL_STEP:-} != sign ]] || exit 44
    mkdir -p "$app/Contents/_CodeSignature"
    printf 'new signature\n' > "$app/Contents/_CodeSignature/CodeResources"
else
    [[ ${FAIL_STEP:-} != verify ]] || exit 45
    if [[ ${FAIL_STEP:-} == publish_missing ]]; then rm -rf "$app"; fi
    if [[ ${FAIL_STEP:-} == launch_before_publish ]]; then
        "$FIXTURE/build/Zipper.app/Contents/MacOS/Zipper" 60 </dev/null >/dev/null 2>&1 &
        printf '%s\n' "$!" > "$TEST_ROOT/running-pid"
        # Wait until the child has exec'd so the kernel path check is exercised.
        for ((i=0; i<100; i++)); do
            if /bin/ps -p "$!" -o comm= | /usr/bin/grep -F 'Contents/MacOS/Zipper' >/dev/null; then break; fi
            /bin/sleep 0.01
        done
    fi
fi
STUB
chmod +x "$TEST_ROOT/bin/"*
export TEST_ROOT FIXTURE
export PATH="$TEST_ROOT/bin:$PATH"

reset_fixture() {
    stop_fixture_process
    rm -rf "$FIXTURE" "$TEST_ROOT/snapshot" "$TEST_ROOT/build-started"
    mkdir -p "$FIXTURE/scripts" "$FIXTURE/build"
    cp "$REPO/scripts/package.sh" "$REPO/scripts/publish-app.swift" "$FIXTURE/scripts/"
    cp -R "$TEMPLATE" "$FIXTURE/build/Zipper.app"
    cp -R "$FIXTURE/build/Zipper.app" "$TEST_ROOT/snapshot"
}

expect_unchanged_failure() {
    local name=$1
    if "$FIXTURE/scripts/package.sh" > "$TEST_ROOT/last-run.txt" 2>&1; then
        printf 'FAIL: %s unexpectedly succeeded\n' "$name" >&2
        exit 1
    fi
    diff -r "$TEST_ROOT/snapshot" "$FIXTURE/build/Zipper.app"
    [[ ! -e "$FIXTURE/build/.package-lock" ]]
    local leftovers=("$FIXTURE/build/".package-*)
    [[ ! -e "${leftovers[0]}" ]]
    printf 'PASS: %s preserves the entire previous bundle and cleans staging\n' "$name"
}

for step in compiler build missing_binary icon sign verify publish_missing; do
    reset_fixture
    export FAIL_STEP=$step
    expect_unchanged_failure "$step failure"
done

reset_fixture
export FAIL_STEP=''
"$FIXTURE/build/Zipper.app/Contents/MacOS/Zipper" 60 &
printf '%s\n' "$!" > "$TEST_ROOT/running-pid"
for ((i=0; i<100; i++)); do
    if /bin/ps -p "$!" -o comm= | /usr/bin/grep -F 'Contents/MacOS/Zipper' >/dev/null; then break; fi
    /bin/sleep 0.01
done
expect_unchanged_failure 'already running application'
[[ ! -e "$TEST_ROOT/build-started" ]]
printf 'PASS: running application is blocked before release compilation\n'

reset_fixture
export FAIL_STEP=launch_before_publish
expect_unchanged_failure 'application launched during build'

reset_fixture
export FAIL_STEP=''
mkdir "$FIXTURE/build/.package-lock"
if "$FIXTURE/scripts/package.sh" > "$TEST_ROOT/last-run.txt" 2>&1; then exit 1; fi
diff -r "$TEST_ROOT/snapshot" "$FIXTURE/build/Zipper.app"
[[ ! -e "$TEST_ROOT/build-started" ]]
[[ -d "$FIXTURE/build/.package-lock" ]]
printf 'PASS: competing package run cannot acquire or remove an existing lock\n'

reset_fixture
"$FIXTURE/scripts/package.sh" > "$TEST_ROOT/last-run.txt" 2>&1
[[ $(cat "$FIXTURE/build/Zipper.app/Contents/MacOS/Zipper") == 'new executable' ]]
[[ $(cat "$FIXTURE/build/Zipper.app/Contents/Resources/Zipper.icns") == 'new icon' ]]
[[ $(cat "$FIXTURE/build/Zipper.app/Contents/_CodeSignature/CodeResources") == 'new signature' ]]
[[ ! -e "$FIXTURE/build/.package-lock" ]]
printf 'PASS: complete staged application atomically replaces previous application\n'

reset_fixture
rm -rf "$FIXTURE/build/Zipper.app"
"$FIXTURE/scripts/package.sh" > "$TEST_ROOT/last-run.txt" 2>&1
[[ $(cat "$FIXTURE/build/Zipper.app/Contents/MacOS/Zipper") == 'new executable' ]]
printf 'PASS: first build publishes a complete application\n'

reset_fixture
mv "$FIXTURE/build/Zipper.app" "$FIXTURE/elsewhere.app"
ln -s ../elsewhere.app "$FIXTURE/build/Zipper.app"
if "$FIXTURE/scripts/package.sh" > "$TEST_ROOT/last-run.txt" 2>&1; then exit 1; fi
diff -r "$TEST_ROOT/snapshot" "$FIXTURE/elsewhere.app"
[[ -L "$FIXTURE/build/Zipper.app" ]]
printf 'PASS: symlink application target is rejected without touching its destination\n'

reset_fixture
mv "$FIXTURE/build" "$FIXTURE/elsewhere-build"
ln -s elsewhere-build "$FIXTURE/build"
if "$FIXTURE/scripts/package.sh" > "$TEST_ROOT/last-run.txt" 2>&1; then exit 1; fi
diff -r "$TEST_ROOT/snapshot" "$FIXTURE/elsewhere-build/Zipper.app"
printf 'PASS: symlink build directory is rejected\n'

printf 'All packaging regressions passed; real application and footage untouched.\n'
