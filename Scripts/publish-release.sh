#!/bin/bash
# Local-only release driver. Never export signing keys or upload them to CI.
set -euo pipefail

usage() {
    echo 'Usage: bash Scripts/publish-release.sh [--check | --dry-run | --publish]'
    echo '  --check    Check credentials, repository and version; no build or publish.'
    echo '  --dry-run  Test, build, sign, notarize with Apple, and stage locally (default).'
    echo '  --publish  Also push committed main + tag and publish a GitHub release.'
    echo 'All modes require a clean main branch. See Docs/Releasing.md for setup.'
}
mode=${1:---dry-run}
[[ $# -le 1 ]] || { usage; exit 2; }
case "$mode" in --help|-h) usage; exit 0 ;; --check|--dry-run|--publish) ;; *) usage; exit 2 ;; esac
fail() { echo "Release stopped: $*" >&2; exit 1; }
[[ "$(uname -s)" == Darwin ]] || fail 'Run this on your signing Mac.'
[[ -z "${GITHUB_ACTIONS:-}" ]] || fail 'Signing must run locally, not in GitHub Actions.'
cd "$(dirname "$0")/.."
project_root=$PWD
repository=Phoenix1485/NativeAgent
site_url=https://phoenix1485.github.io/NativeAgent/
export NATIVEAGENT_SIGNING_IDENTITY=${NATIVEAGENT_SIGNING_IDENTITY:-Developer ID Application: Len Knoche (N5ZXADUHPB)}
notary_profile=${NATIVEAGENT_NOTARY_PROFILE:-NativeAgent-Notary}
sparkle_account=${NATIVEAGENT_SPARKLE_ACCOUNT:-dev.nativeagent.mac.updates}
gh_cli=${NATIVEAGENT_GH:-gh}
if ! command -v "$gh_cli" >/dev/null 2>&1 && [[ -x .build/tools/gh ]]; then gh_cli="$PWD/.build/tools/gh"; fi
for tool in git swift python3 codesign ditto xcrun "$gh_cli"; do command -v "$tool" >/dev/null || fail "Missing tool: $tool"; done
gh() { command "$gh_cli" "$@"; }
clean_main() {
    [[ "$(git rev-parse --show-toplevel)" == "$project_root" ]] || fail 'Initialize this project as its own Git repository first.'
    [[ "$(git branch --show-current)" == main ]] || fail 'Switch to main before releasing.'
    [[ -z "$(git status --porcelain --untracked-files=all)" ]] || fail 'Commit all changes before releasing; nothing is auto-staged or auto-committed.'
}
clean_main
origin=$(git remote get-url --push origin)
case "$origin" in "https://github.com/$repository"|"https://github.com/$repository.git"|"git@github.com:$repository.git") ;; *) fail 'origin must point to Phoenix1485/NativeAgent.' ;; esac
commit=$(git rev-parse HEAD)
plist=NativeAgent/Resources/Info.plist
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'Use a numeric major.minor.patch version.'
[[ "$build" =~ ^[1-9][0-9]*$ ]] || fail 'Use a positive integer CFBundleVersion, incremented for every release.'
tag="v$version-build.$build"
git show-ref --verify --quiet "refs/tags/$tag" && fail "Tag $tag already exists locally; never overwrite a released version."
gh auth status --hostname github.com >/dev/null
check_remote() {
    # A failed request is never treated as an empty repository.
    gh api --paginate "repos/$repository/releases?per_page=100" --jq '.[].tag_name' |
        python3 Scripts/release-tools.py history "$tag"
    remote_tag=$(git ls-remote --tags origin "refs/tags/$tag")
    [[ -z "$remote_tag" ]] || fail "Tag $tag already exists on GitHub."
    remote_head=$(git ls-remote --heads origin refs/heads/main | awk '{print $1}')
    if [[ -n "$remote_head" ]]; then
        git fetch --no-tags origin main
        git merge-base --is-ancestor "$remote_head" "$commit" || fail 'Remote main is ahead or diverged. Integrate it before releasing.'
    fi
}
check_remote
security find-identity -v -p codesigning | grep -F -- "\"$NATIVEAGENT_SIGNING_IDENTITY\"" >/dev/null || fail 'Developer ID signing identity is not available in your Keychain.'
swift package resolve
sparkle_bin="$PWD/.build/artifacts/sparkle/Sparkle/bin"
# Look up only the PUBLIC key. Never generate or export a private key here.
public_key=$("$sparkle_bin/generate_keys" --account "$sparkle_account" -p)
expected_key=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$plist")
[[ "$public_key" == "$expected_key" ]] || fail 'Local Sparkle key does not match the app public key.'
xcrun notarytool history --keychain-profile "$notary_profile" --output-format json >/dev/null
echo "Preflight passed: $tag ($commit). Signing keys remain in your local Keychain."
[[ "$mode" != --check ]] || exit 0

mkdir -p dist
lock="$PWD/dist/local-release.lock"
mkdir "$lock" 2>/dev/null || fail 'Another local release is running (see Docs/Releasing.md for stale-lock recovery).'
trap 'rmdir "$lock" 2>/dev/null || true' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# An isolated committed snapshot excludes concurrent editor changes.
run_dir=$(mktemp -d "$PWD/dist/release-${tag}.XXXXXX")
# Documents may be iCloud/File Provider managed, which can attach FinderInfo to
# .app/.xpc directories and invalidate code signing. Build in the local temp area;
# only ZIP/XML/JSON release artifacts are retained under the workspace's dist/.
source_dir=$(mktemp -d "${TMPDIR:-/tmp}/nativeagent-release-source.XXXXXX")
printf '%s\n' "$source_dir" > "$run_dir/source-directory.txt"
git archive "$commit" | tar -x -C "$source_dir"
cd "$source_dir"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
echo 'Running tests against the exact source snapshot to be released...'
swift test --disable-sandbox -j 4
python3 -m unittest discover -s Scripts/tests
bash -n Scripts/build-release.sh Scripts/publish-release.sh
swift Scripts/tests/verify-update-tests.swift
export NATIVEAGENT_UNIVERSAL=1
unset NATIVEAGENT_BUILD_NUMBER
bash Scripts/build-release.sh
binary_root=$(swift build -c release --disable-sandbox --arch arm64 --arch x86_64 --show-bin-path)
app="$binary_root/NativeAgent.app"
lipo -verify_arch arm64 x86_64 "$app/Contents/MacOS/NativeAgent"
codesign --verify --deep --strict "$app"

echo 'Submitting signed app to Apple for notarization...'
ditto -c -k --sequesterRsrc --keepParent "$app" "$run_dir/notarization.zip"
xcrun notarytool submit "$run_dir/notarization.zip" --keychain-profile "$notary_profile" --wait --output-format json > "$run_dir/notarization.json"
python3 Scripts/release-tools.py notarization "$run_dir/notarization.json"
xcrun stapler staple "$app"
xcrun stapler validate "$app"
codesign --verify --deep --strict "$app"
spctl --assess --type execute --verbose=2 "$app"

archive_dir="$run_dir/artifacts"
mkdir "$archive_dir"
archive="$archive_dir/NativeAgent-$build.zip"
# Staple FIRST, then archive and sign the final, immutable bytes.
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
"$sparkle_bin/generate_appcast" --account "$sparkle_account" --maximum-deltas 0 \
    --download-url-prefix "https://github.com/$repository/releases/download/$tag/" --link "$site_url" "$archive_dir"
swift Scripts/verify-update.swift "$expected_key" "$archive_dir/appcast.xml" "$archive"
python3 Scripts/prepare-update-site.py --source Site --destination "$run_dir/site" --app "$app" \
    --archive "$archive" --appcast "$archive_dir/appcast.xml" --repository "$repository" \
    --tag "$tag" --commit "$commit" --notarized true
cp "$run_dir/site/release.json" "$run_dir/site/SHA256SUMS.txt" "$archive_dir/"
echo "Verified release artifacts: $archive_dir"
if [[ "$mode" == --dry-run ]]; then
    echo 'Dry run complete. Apple notarization succeeded; nothing was pushed or published to GitHub.'
    exit 0
fi

cd "$project_root"
clean_main
[[ "$(git rev-parse HEAD)" == "$commit" ]] || fail 'HEAD changed during the build. Nothing will be published.'
check_remote
# Atomic push, no force, no deletion, no implicit staging.
git push --atomic origin "$commit:refs/heads/main" "$commit:refs/tags/$tag"
git tag "$tag" "$commit"
echo "Source and tag pushed. Preparing draft release $tag..."
gh release create "$tag" "$archive" "$archive_dir/appcast.xml" "$archive_dir/release.json" "$archive_dir/SHA256SUMS.txt" \
    --repo "$repository" --verify-tag --draft --title "NativeAgent $version ($build)" \
    --notes "Universal macOS 14+ app. Developer ID signed and Apple-notarized. Archive and feed are Ed25519-signed locally. Source: $commit."
# A failed upload leaves only a draft, never a broken public update.
gh release edit "$tag" --repo "$repository" --draft=false --latest
echo "Published https://github.com/$repository/releases/tag/$tag"
echo "GitHub Actions will verify signatures and deploy $site_url. Check the Pages workflow before announcing the update."
