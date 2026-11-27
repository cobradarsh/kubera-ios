#!/bin/bash
# Builds Kubera.ipa: the SwiftUI app (iOS 16.0+), ad-hoc signed with the TrollStore entitlements in
# App/app.entitlements (no sandbox + Messages storage, so it can read sms.db). Needs Xcode; no project file.
set -euo pipefail
cd "$(dirname "$0")"

OUT=build
APP="$OUT/Payload/Kubera.app"
MIN_IOS=16.0
rm -rf "$OUT"
mkdir -p "$APP"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
echo "== swift $(xcrun --sdk iphoneos swiftc --version 2>&1 | head -1)"
SOURCES=$(find App -name '*.swift' | sort)
echo "$SOURCES" | sed 's/^/   /'
# shellcheck disable=SC2086
xcrun --sdk iphoneos swiftc \
    -target arm64-apple-ios$MIN_IOS -sdk "$SDK" \
    -swift-version 5 -O -wmo -parse-as-library \
    -module-name Kubera \
    -lsqlite3 \
    -Xlinker -dead_strip \
    $SOURCES \
    -o "$APP/Kubera" 2>&1 | grep -v "^ld: warning: .*was built for newer iOS version" || true
[ -f "$APP/Kubera" ] || { echo "swiftc failed"; exit 1; }

echo "== resources"
cp App/Resources/*.json "$APP/"

echo "== asset catalog"
xcrun actool App/Assets.xcassets --compile "$APP" --platform iphoneos \
    --minimum-deployment-target "$MIN_IOS" --target-device iphone \
    --app-icon AppIcon --output-partial-info-plist "$OUT/assets-info.plist" \
    --errors --warnings --output-format human-readable-text

echo "== Info.plist"
cp App/Info.plist "$APP/Info.plist"
/usr/libexec/PlistBuddy -c "Merge $OUT/assets-info.plist" "$APP/Info.plist"
plutil -lint "$APP/Info.plist"
plutil -convert binary1 "$APP/Info.plist"
printf 'APPL????' > "$APP/PkgInfo"

echo "== sign (TrollStore keeps these entitlements)"
codesign --force --sign - --timestamp=none --generate-entitlement-der --entitlements App/app.entitlements "$APP"

echo "== package"
(cd "$OUT" && zip -qry Kubera.ipa Payload)
ls -la "$OUT"
