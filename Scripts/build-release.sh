#!/bin/bash
set -euo pipefail

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_root="$project_root/.build"
module_cache="$build_root/module-cache"
clang_cache="$build_root/clang-cache"

cd "$project_root"
export SWIFTPM_MODULECACHE_OVERRIDE="$module_cache"
export CLANG_MODULE_CACHE_PATH="$clang_cache"
build_args=(-c release --disable-sandbox)
if [[ "${NATIVEAGENT_UNIVERSAL:-0}" == 1 ]]; then
    build_args+=(--arch arm64 --arch x86_64)
fi
swift build "${build_args[@]}"
binary_root=$(swift build "${build_args[@]}" --show-bin-path)

app="$binary_root/NativeAgent.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp "$binary_root/NativeAgent" "$app/Contents/MacOS/NativeAgent"
cp "$project_root/NativeAgent/Resources/Info.plist" "$app/Contents/Info.plist"
ditto "$binary_root/NativeAgent_NativeAgent.bundle" "$app/Contents/Resources/NativeAgent_NativeAgent.bundle"
ditto "$build_root/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
cp "$build_root/artifacts/sparkle/Sparkle/LICENSE" "$app/Contents/Resources/Sparkle-LICENSE.txt"
if [[ -n "${NATIVEAGENT_BUILD_NUMBER:-}" ]]; then
    [[ "$NATIVEAGENT_BUILD_NUMBER" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || { echo "Invalid build number" >&2; exit 1; }
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NATIVEAGENT_BUILD_NUMBER" "$app/Contents/Info.plist"
fi
# Developer ID is optional until an Apple Developer account is configured.
# Never disable Gatekeeper or remove quarantine as part of this build.
if [[ -n "${NATIVEAGENT_SIGNING_IDENTITY:-}" ]]; then
    framework="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
    for component in "$framework/XPCServices/Downloader.xpc" "$framework/XPCServices/Installer.xpc" "$framework/Autoupdate" "$framework/Updater.app"; do
        codesign --force --sign "$NATIVEAGENT_SIGNING_IDENTITY" --options runtime --timestamp --preserve-metadata=entitlements "$component"
    done
    codesign --force --sign "$NATIVEAGENT_SIGNING_IDENTITY" --options runtime --timestamp "$app/Contents/Frameworks/Sparkle.framework"
    codesign --force --sign "$NATIVEAGENT_SIGNING_IDENTITY" --options runtime --timestamp "$app"
else
    codesign --force --sign - "$app"
fi
codesign --verify --deep --strict "$app"
size=$(du -sh "$app" | awk '{print $1}')
echo "Built $app ($size)"
