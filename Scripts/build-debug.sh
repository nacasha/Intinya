#!/bin/sh
#
# Builds Intinya.app from the SwiftPM product and signs it.
#
# Two things make this a script rather than a plain `swift build`:
#
#   * A bare SwiftPM executable cannot hold TCC permissions. macOS grants
#     Microphone and Screen Recording to a signed .app bundle, not a loose
#     binary, so the bundle has to be assembled by hand.
#   * Signing matters more here than it does for most apps. Those grants are
#     recorded against the code signature, so an ad hoc build is a different
#     app to macOS every rebuild and asks for both again — worse, a microphone
#     grant that is not in effect yields digital silence rather than an error.
#     Signing with the same Developer ID each time means they stay granted.
#
#   Scripts/build-debug.sh                    build, sign, and report
#   Scripts/build-debug.sh --run              also relaunch the app
#   Scripts/build-debug.sh --reveal           also reveal it in Finder
#   CONFIG=debug Scripts/build-debug.sh       faster build, slower transcription
#   UNIVERSAL=1 VERSION=1.2.0 Scripts/build-debug.sh    what the release job runs
#
set -eu

cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP="${APP:-build/Intinya.app}"
# Unchanged by the rename to Intinya, deliberately. TCC records Microphone and
# Screen Recording grants against the bundle id, so a new one is a new app to
# macOS: both permissions would need granting again, and a stale mic grant
# yields digital silence rather than an error — see the note at the top.
BUNDLE_ID="${BUNDLE_ID:-com.izalfathoni.meeting}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

# Only set when Xcode 26 is not the one selected. Left alone on CI, where the
# runner's Xcode is whatever the image ships and this path does not exist.
if [ -d "/Applications/Xcode-26.3.0.app" ]; then
    export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-26.3.0.app/Contents/Developer}"
fi

IDENTITY="${IDENTITY:-$(security find-identity -v -p codesigning \
    | grep "Developer ID Application" \
    | head -1 \
    | awk -F'"' '{print $2}')}"

if [ "${UNIVERSAL:-0}" = "1" ]; then
    # SwiftPM cannot resolve the package graph for two architectures at once
    # here (duplicate ArgmaxCLI module id), so each slice is built alone and
    # merged afterwards.
    echo "==> Building arm64 ($CONFIG)"
    swift build -c "$CONFIG" --arch arm64 > /dev/null
    ARM_BIN="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)/Intinya"

    echo "==> Building x86_64 ($CONFIG)"
    swift build -c "$CONFIG" --arch x86_64 > /dev/null
    X86_BIN="$(swift build -c "$CONFIG" --arch x86_64 --show-bin-path)/Intinya"
else
    echo "==> Building ($CONFIG)"
    swift build -c "$CONFIG"
    ARM_BIN="$(swift build -c "$CONFIG" --show-bin-path)/Intinya"
    X86_BIN=""
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [ -n "$X86_BIN" ]; then
    lipo -create "$ARM_BIN" "$X86_BIN" -output "$APP/Contents/MacOS/Intinya"
else
    cp "$ARM_BIN" "$APP/Contents/MacOS/Intinya"
fi
lipo -archs "$APP/Contents/MacOS/Intinya" | sed 's/^/    /'

# Regenerated only when the artwork is newer, so a normal build pays nothing.
if [ -f Resources/AppIcon.png ] && \
   { [ ! -f Resources/Intinya.icns ] || [ Resources/AppIcon.png -nt Resources/Intinya.icns ]; }; then
    sh Scripts/make-icon.sh
fi
if [ -f Resources/Intinya.icns ]; then
    cp Resources/Intinya.icns "$APP/Contents/Resources/Intinya.icns"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>Intinya</string>
    <key>CFBundleDisplayName</key>       <string>Intinya</string>
    <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>        <string>Intinya</string>
    <key>CFBundleIconFile</key>          <string>Intinya</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key>           <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Intinya records your microphone so your side of the conversation is transcribed.</string>
</dict>
</plist>
PLIST

if [ -n "$IDENTITY" ]; then
    # Nested code first, then the bundle. Signing the .app only covers its main
    # executable, and dyld refuses to map libraries whose Team ID differs from
    # the process, so anything left ad hoc inside crashes the app at launch.
    find "$APP/Contents" \( -name '*.dylib' -o -name '*.framework' \) -print0 2>/dev/null \
        | xargs -0 -I{} codesign --force --sign "$IDENTITY" --options runtime {} 2>/dev/null || true

    # --timestamp needs the network and is only wanted for something handed to
    # somebody else, so the release job asks for it and a local build does not.
    # shellcheck disable=SC2086
    codesign --force --sign "$IDENTITY" \
        --entitlements Intinya.entitlements \
        --options runtime \
        ${TIMESTAMP:+--timestamp} \
        "$APP"
    codesign --verify --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'
    echo "==> Signed as: $IDENTITY"
else
    echo "==> Signing ad hoc — no Developer ID identity found"
    echo "    warning: Microphone and Screen Recording will need granting again" >&2
    echo "    warning: after every rebuild, and a stale mic grant records silence." >&2
    codesign --force --sign - \
        --entitlements Intinya.entitlements \
        --options runtime \
        "$APP"
fi

echo "==> Built $APP  ($VERSION build $BUILD_NUMBER)"

case "${1:-}" in
    --run)
        # Rebuilding underneath a running copy silently leaves you testing the
        # old binary, so the running one is stopped rather than left alone.
        pkill -f 'Intinya.app/Contents/MacOS/Intinya' 2>/dev/null || true
        open "$APP"
        ;;
    --reveal)
        open -R "$APP"
        ;;
esac
