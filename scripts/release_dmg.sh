#!/bin/zsh
# Builds the DMG for a GitHub release of KlipLoft Mini: archives the app, exports it with Developer ID,
# and notarizes and staples both the app and the DMG, so it opens without Gatekeeper warnings.
#
# Needs Config/Local.xcconfig with your team and a notarytool Keychain profile
# (xcrun notarytool store-credentials).
#
# Usage: scripts/release_dmg.sh [notarytool profile]   (default: klip-notary)
# Writes build/release/KlipLoft-Mini-<version>.dmg and prints the version, build and SHA256 for the
# release notes and the Homebrew cask.
set -euo pipefail

profile=${1:-klip-notary}
root=${0:A:h:h}
cd "$root"
[[ -f Config/Local.xcconfig ]] || { echo "Config/Local.xcconfig is missing (see Config/Local.example.xcconfig)"; exit 1; }

out=build/release
rm -rf "$out"
mkdir -p "$out"

# Submits a file to Apple's notary service and fails unless it's accepted.
notarize() {
    local result
    result=$(xcrun notarytool submit "$1" --keychain-profile "$profile" --wait --output-format json)
    [[ $(plutil -extract status raw - <<< "$result") == Accepted ]] || { echo "Notarization failed: $result"; exit 1; }
}

echo "Archiving…"
xcodebuild -project KlipLoftMini.xcodeproj -scheme KlipLoftMini -configuration Release \
    -derivedDataPath build/DD-release -archivePath "$out/Mini.xcarchive" archive -quiet

cat > "$out/ExportOptions.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>developer-id</string>
<key>signingStyle</key><string>automatic</string>
<key>destination</key><string>export</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$out/Mini.xcarchive" -exportPath "$out/export" \
    -exportOptionsPlist "$out/ExportOptions.plist" -quiet

app="$out/export/KlipLoft Mini.app"
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$app/Contents/Info.plist")
team=$(codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')

echo "Notarizing KlipLoft Mini $version ($build)…"
ditto -c -k --keepParent "$app" "$out/app.zip"
notarize "$out/app.zip"
xcrun stapler staple -q "$app"

dmg="$out/KlipLoft-Mini-$version.dmg"
scripts/make_dmg.sh "$app" "$dmg"
identity=$(security find-identity -v -p codesigning | sed -n "s/.*\"\(Developer ID Application: .*($team)\)\"/\1/p" | head -1)
codesign --sign "$identity" --timestamp "$dmg"
echo "Notarizing the DMG…"
notarize "$dmg"
xcrun stapler staple -q "$dmg"
spctl -a -t open --context context:primary-signature -v "$dmg"

echo
echo "version $version"
echo "build   $build"
echo "sha256  $(shasum -a 256 "$dmg" | cut -d' ' -f1)"
echo "DMG:    $dmg"
