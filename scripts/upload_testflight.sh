#!/bin/zsh
# Uploads a build of KlipLoft Mini to App Store Connect (TestFlight, then the App Store): archives the
# app and exports it for the App Store, which uploads it with the Apple account signed in to Xcode.
# The App Store is the only official build of Mini: there's no DMG.
#
# Needs Config/Local.xcconfig with your team.
#
# Usage: scripts/upload_testflight.sh [--export-only]
#   --export-only  signs for the App Store into build/appstore/export without uploading
set -euo pipefail

destination=upload
[[ ${1:-} == --export-only ]] && destination=export
root=${0:A:h:h}
cd "$root"
[[ -f Config/Local.xcconfig ]] || { echo "Config/Local.xcconfig is missing (see Config/Local.example.xcconfig)"; exit 1; }

out=build/appstore
rm -rf "$out"
mkdir -p "$out"

echo "Archiving…"
xcodebuild -project KlipLoftMini.xcodeproj -scheme KlipLoftMini -configuration Release \
    -derivedDataPath build/DD-release -archivePath "$out/Mini.xcarchive" archive -quiet

cat > "$out/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>app-store-connect</string>
<key>destination</key><string>$destination</string>
<key>signingStyle</key><string>automatic</string>
<key>uploadSymbols</key><true/>
<key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST

info="$out/Mini.xcarchive/Products/Applications/KlipLoft Mini.app/Contents/Info.plist"
echo "Exporting KlipLoft Mini $(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$info") ($(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$info")) for the App Store ($destination)…"
xcodebuild -exportArchive -archivePath "$out/Mini.xcarchive" -exportPath "$out/export" \
    -exportOptionsPlist "$out/ExportOptions.plist" -quiet
echo "Done."
