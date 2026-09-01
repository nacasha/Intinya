#!/bin/sh
#
# Builds Resources/Intinya.icns from Resources/AppIcon.png.
#
# Separate from the build script because it only needs to run when the artwork
# changes, and because the .icns is committed: contributors without the source
# PNG's tooling still get an icon, and CI does not depend on iconutil.
#
# The source is expected to be 1024x1024 with transparency and the rounded
# shape already drawn. macOS applies no mask of its own — unlike iOS, an .icns
# is composited exactly as authored — so a square source would render square.
#
#   Scripts/make-icon.sh
#
set -eu

cd "$(dirname "$0")/.."

SRC="Resources/AppIcon.png"
OUT="Resources/Intinya.icns"
SET="$(mktemp -d)/Intinya.iconset"

[ -f "$SRC" ] || { echo "missing $SRC" >&2; exit 1; }

mkdir -p "$SET"

# Both scales of every size macOS asks for. The @2x of one size and the @1x of
# the next are the same pixel dimensions but not interchangeable: macOS picks by
# name, and omitting one leaves that slot to be upscaled from a smaller image.
for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
            "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" \
            "512 512x512" "1024 512x512@2x"; do
    px="${spec%% *}"
    name="${spec#* }"
    sips -z "$px" "$px" "$SRC" --out "$SET/icon_$name.png" > /dev/null
done

iconutil -c icns "$SET" -o "$OUT"
rm -rf "$(dirname "$SET")"

echo "==> Built $OUT ($(du -h "$OUT" | cut -f1))"
