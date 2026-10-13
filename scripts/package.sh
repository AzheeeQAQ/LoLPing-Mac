#!/bin/zsh
# Universal (Apple Silicon + Intel) release build, packaged with a one-click
# installer for friends: dist/LoLPing-v<version>-server-macOS-universal.zip
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/module-cache .build/cache .build/config .build/security .build/package
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)

# Separate scratch paths so the two architectures never clobber each other.
slices=()
for arch in arm64 x86_64; do
    flags=(-c release --product LoLPing --build-system native --triple "$arch-apple-macosx13.0"
           --scratch-path "$PWD/.build/package-$arch" --disable-sandbox
           --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security")
    swift build "${flags[@]}"
    slices+=("$(swift build "${flags[@]}" --show-bin-path)/LoLPing")
done
lipo -create "${slices[@]}" -output .build/package/LoLPing
lipo -info .build/package/LoLPing

# Same bundle layout as build.sh, assembled from scratch.
APP="$PWD/dist/LoLPing.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/package/LoLPing "$APP/Contents/MacOS/LoLPing"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/Artwork Resources/Icons Resources/Sounds "$APP/Contents/Resources/"
if [[ -d Resources/RelayTrust ]]; then cp -R Resources/RelayTrust "$APP/Contents/Resources/"; fi
source scripts/embed-sparkle.sh
embed_sparkle "$APP" "$PWD/.build/package-arm64"
cp Resources/asset-sources.json "$APP/Contents/Resources/"
swift scripts/make_icon.swift "$PWD/.build/AppIcon.iconset"
iconutil -c icns .build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - --identifier local.allentu.LoLPing "$APP"
codesign --verify --deep --strict "$APP"
"$APP/Contents/MacOS/LoLPing" --check-assets

KIT="$PWD/dist/LoLPing-Server"
ZIP="$PWD/dist/LoLPing-v$VERSION-server-macOS-universal.zip"
rm -rf "$KIT" "$ZIP"
mkdir -p "$KIT"
ditto "$APP" "$KIT/LoLPing.app"
cp scripts/installer/install.command scripts/installer/使用说明.txt "$KIT/"
chmod +x "$KIT/install.command"
ditto -c -k --sequesterRsrc --keepParent "$KIT" "$ZIP"
print "Packaged: $ZIP ($(du -h "$ZIP" | cut -f1))"
