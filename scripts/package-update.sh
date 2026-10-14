#!/bin/zsh -f
# Produce a signed, App-only ZIP plus signed Sparkle appcast. No private key is
# uploaded: signing uses the dedicated local login Keychain item by default.
set -euo pipefail
cd "${0:A:h:h}"
APP="$PWD/dist/LoLPing.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")
TOOLS="$PWD/.build/artifacts/sparkle/Sparkle/bin"
SIGNING=(--account local.allentu.LoLPing)
# Optional local file for headless signing sessions where Keychain won't let a
# second tool read the item. Never put the file in the repository or uploads.
if [[ -n "${LOLPING_UPDATE_KEY_FILE:-}" ]]; then SIGNING+=(--ed-key-file "$LOLPING_UPDATE_KEY_FILE"); fi
STAGING="$PWD/.build/update-$VERSION"
ARCHIVE="LoLPing-v$VERSION-update-macOS-universal.zip"
[[ "$VERSION" == <->.<->.<-> && "$BUILD" == <-> ]] || { print -u2 'Invalid release version/build.'; exit 1; }
[[ $# == 1 && -s "$1" ]] || { print -u2 'Usage: zsh scripts/package-update.sh updates/release-notes/<version>.txt'; exit 1; }
[[ ! -e "downloads/$ARCHIVE" ]] || { print -u2 'Published update archives are immutable. Bump version/build to release a new update.'; exit 1; }
[[ "$("$TOOLS/generate_keys" --account local.allentu.LoLPing -p)" == "$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' "$APP/Contents/Info.plist")" ]] || { print -u2 'Update signing key does not match the App.'; exit 1; }
zsh scripts/sign-app.sh --verify "$APP"
lipo "$APP/Contents/MacOS/LoLPing" -verify_arch arm64 x86_64
"$APP/Contents/MacOS/LoLPing" --check-assets
mkdir -p "$STAGING" downloads updates
ditto -c -k --sequesterRsrc --keepParent "$APP" "$STAGING/$ARCHIVE"
cp "$1" "$STAGING/${ARCHIVE:r}.txt"
if [[ -f updates/appcast.xml ]]; then cp updates/appcast.xml "$STAGING/appcast.xml"; fi
"$TOOLS/generate_appcast" "${SIGNING[@]}" --maximum-deltas 0 --maximum-versions 0 \
    --embed-release-notes --download-url-prefix "https://raw.githubusercontent.com/AzheeeQAQ/LoLPing-Mac/refs/tags/v$VERSION/downloads/" \
    -o "$STAGING/appcast.xml" "$STAGING"
"$TOOLS/sign_update" "${SIGNING[@]}" --verify "$STAGING/appcast.xml"
cp "$STAGING/$ARCHIVE" "downloads/$ARCHIVE"
cp "$STAGING/appcast.xml" updates/appcast.xml
print "Update archive: downloads/$ARCHIVE"
print 'Signed feed: updates/appcast.xml'
print "Publish the feed and archive together, with immutable tag v$VERSION."
