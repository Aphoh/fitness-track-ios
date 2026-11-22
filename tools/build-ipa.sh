#!/usr/bin/env bash
#
# build-ipa.sh <version> [build-number] — unsigned Release device build of FitnessTrack,
# packaged as FitnessTrack-ios-unsigned-v<version>.ipa for SideStore / Sideloadly / AltStore.
#
# Release, not Debug: a Debug build carries get-task-allow, which makes re-signed sideloads
# fail with "integrity could not be verified". The app has no entitlements, so the sideloader
# re-signs it with the user's free Apple ID as-is.
set -euo pipefail

VER="${1:?usage: $0 <version> [build-number]}"
BUILD="${2:-1}"
[[ "$VER" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || { echo "✗ version must be MAJOR[.MINOR[.PATCH]], got '$VER'" >&2; exit 1; }
[[ "$BUILD" =~ ^[0-9]+$ ]] || { echo "✗ build number must be an integer, got '$BUILD'" >&2; exit 1; }

cd "$(dirname "$0")/.."
DD="${DERIVED_DATA:-build/dd}"
IPA="$PWD/FitnessTrack-ios-unsigned-v${VER}.ipa"

xcodebuild -project FitnessTrack.xcodeproj -scheme FitnessTrack \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath "$DD" \
  MARKETING_VERSION="$VER" CURRENT_PROJECT_VERSION="$BUILD" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build

APP="$DD/Build/Products/Release-iphoneos/FitnessTrack.app"
[ -f "$APP/Info.plist" ] || { echo "✗ $APP/Info.plist not found" >&2; exit 1; }

STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
mkdir "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
rm -f "$IPA"
(cd "$STAGE" && zip -qry "$IPA" Payload)

PLIST="$STAGE/Payload/FitnessTrack.app/Info.plist"
echo "✓ $(basename "$IPA"): $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")" \
  "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")" \
  "($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")), $(stat -f%z "$IPA") bytes"
