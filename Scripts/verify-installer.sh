#!/bin/bash
# No execution or installation of downloaded code. Verify the sealed container.
set -euo pipefail
[[ $# == 1 && -f "$1" && "$1" == *.dmg ]] || { echo 'Expected a DMG installer.' >&2; exit 2; }
hdiutil verify "$1"
codesign --verify --strict "$1"
team=$(codesign -d --verbose=4 "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p')
[[ "$team" == N5ZXADUHPB ]] || { echo 'Installer was not signed by the NativeAgent developer.' >&2; exit 1; }
xcrun stapler validate "$1"
echo 'Verified Developer ID signature and stapled notarization ticket for the installer.'
