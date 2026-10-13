#!/bin/zsh -f
# Source this after compiling: embed_sparkle <app> <swiftpm scratch directory>.
embed_sparkle() {
    local app="$1" scratch="$2"
    local source="$scratch/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
    [[ -d "$source" ]] || { print -u2 'Sparkle framework missing; resolve SwiftPM dependencies first.'; return 1; }
    mkdir -p "$app/Contents/Frameworks"
    rm -rf "$app/Contents/Frameworks/Sparkle.framework"
    ditto "$source" "$app/Contents/Frameworks/Sparkle.framework"
    # Keep the framework's nested helpers and original signatures intact.
    # This app does not enable library validation or the App Sandbox.
    codesign --verify --deep --strict "$app/Contents/Frameworks/Sparkle.framework"
    mkdir -p "$app/Contents/Resources/ThirdParty"
    cp "$scratch/artifacts/sparkle/Sparkle/LICENSE" "$app/Contents/Resources/ThirdParty/Sparkle-LICENSE.txt"
}
