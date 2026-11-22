#!/bin/zsh
# Builds the installer DMG: KlipLoft Mini.app and a link to /Applications, on a volume that shows
# the app's icon when mounted. scripts/release_dmg.sh signs and notarizes it afterwards.
#
# Usage: scripts/make_dmg.sh <KlipLoft Mini.app> <output.dmg>
set -euo pipefail

app=${1:?KlipLoft Mini.app path}
output=${2:?output .dmg path}
root=${0:A:h:h}
work=$(mktemp -d)
trap 'hdiutil detach "$work/mount" -quiet 2>/dev/null || true; rm -rf "$work"' EXIT

mkdir "$work/stage"
ditto "$app" "$work/stage/KlipLoft Mini.app"
ln -s /Applications "$work/stage/Applications"

# The volume icon, from the app's own icon set. Finder rarely draws a disk icon above 256 points,
# and the 512-point images would make up much of the DMG, so they're left out.
iconset="$work/KlipLoftMini.iconset"
mkdir "$iconset"
for points in 16 32 128 256; do
    cp "$root"/KlipLoftMini/Assets.xcassets/AppIcon.appiconset/icon_${points}x${points}{,@2x}.png "$iconset/"
done
iconutil -c icns "$iconset" -o "$work/stage/.VolumeIcon.icns"

# A writable image, so the volume can be marked as having a custom icon, then compressed.
hdiutil create -volname "KlipLoft Mini" -fs APFS -format UDRW -srcfolder "$work/stage" -ov "$work/rw.dmg" -quiet
mkdir "$work/mount"
hdiutil attach "$work/rw.dmg" -mountpoint "$work/mount" -nobrowse -noautoopen -quiet
SetFile -a C "$work/mount"
sync
hdiutil detach "$work/mount" -quiet
hdiutil convert "$work/rw.dmg" -format UDZO -imagekey zlib-level=9 -ov -o "$output" -quiet
echo "Wrote $output"
