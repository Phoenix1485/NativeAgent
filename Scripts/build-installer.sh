#!/bin/bash
# Requires a stapled app. The resulting DMG is signed/notarized afterward.
set -euo pipefail
[[ $# == 2 ]] || { echo 'Usage: bash Scripts/build-installer.sh /path/NativeAgent.app /path/NativeAgent-BUILD.dmg' >&2; exit 2; }
app=$1
destination=$2
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
[[ "$app" == /* && "$destination" == /* && "$destination" == *.dmg && ! -e "$destination" ]] || { echo 'Use absolute paths and a new .dmg destination.' >&2; exit 1; }
[[ -d "$app" && ! -L "$app" && "$(basename "$app")" == NativeAgent.app ]] || { echo 'Expected NativeAgent.app.' >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == dev.nativeagent.mac ]]
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
codesign --verify --deep --strict "$app"
working=$(mktemp -d "${TMPDIR:-/tmp}/nativeagent-dmg.XXXXXX")
staging="$working/content"
mount_dir="$working/mounted"
mkdir "$staging" "$mount_dir"
# Retain temporary build files for diagnosis; never recursively delete user paths.
mounted=0
cleanup() { if [[ "$mounted" == 1 ]]; then hdiutil detach "$mount_dir" || true; fi; }
trap cleanup EXIT
ditto --norsrc --noextattr --qtn "$app" "$staging/NativeAgent.app"
ln -s /Applications "$staging/Applications"
cp "$script_dir/Installer-Read-Me.txt" "$staging/How to install.txt"
size_mb=$(( $(du -sm "$staging" | awk '{print $1}') + 64 ))
hdiutil create -size "${size_mb}m" -fs HFS+ -volname "NativeAgent $version" -srcfolder "$staging" -format UDRW "$working/installer-rw.dmg"
hdiutil attach "$working/installer-rw.dmg" -nobrowse -mountpoint "$mount_dir"
mounted=1
# Only this mounted image's window is customized; no global Finder settings change.
osascript "$script_dir/layout-installer.applescript" "$mount_dir"
[[ -s "$mount_dir/.DS_Store" ]] || { echo 'Finder did not save the installer layout.' >&2; exit 1; }
[[ "$(readlink "$mount_dir/Applications")" == /Applications ]]
codesign --verify --deep --strict "$mount_dir/NativeAgent.app"
cmp "$app/Contents/Info.plist" "$mount_dir/NativeAgent.app/Contents/Info.plist"
cmp "$app/Contents/MacOS/NativeAgent" "$mount_dir/NativeAgent.app/Contents/MacOS/NativeAgent"
xcrun stapler validate "$mount_dir/NativeAgent.app"
hdiutil detach "$mount_dir"
mounted=0
hdiutil convert "$working/installer-rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$destination"
hdiutil verify "$destination"
echo "Created compressed drag-to-Applications installer: $destination"
