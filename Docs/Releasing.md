# Local signed releases

The release command runs on the signing Mac. GitHub Actions receives only source, signed release files and public keys. Do not export Apple or Sparkle private keys into repository secrets. No resident service or background release watcher is installed.

## One-time setup

- Active Apple Developer Program membership and a **Developer ID Application** certificate with its private key in the local Keychain.
- Notarization credentials stored with `xcrun notarytool store-credentials "NativeAgent-Notary"`. Enter the app-specific password at the secure prompt, never in a script or chat.
- Existing Sparkle Keychain account `dev.nativeagent.mac.updates`, matching `SUPublicEDKey` in the app plist. The script looks up its public key and fails on a mismatch; it never regenerates or exports keys. Keep a secure independent backup under your own control.
- Xcode, Python 3 and GitHub CLI (`gh`), authenticated with repository/workflow access: `gh auth login --hostname github.com --git-protocol https --web --scopes workflow`, then `gh auth setup-git`. A workspace-local verified CLI at `.build/tools/gh` is also supported.
- This directory must be a Git repository on `main`, with `origin` set to `https://github.com/Phoenix1485/NativeAgent.git`. For a fresh directory only: `git init -b main`, `git remote add origin https://github.com/Phoenix1485/NativeAgent.git`, review files, then stage and commit the intended source. Never commit credentials, databases, build products or notarization logs.
- Repository Settings → Pages → Source: **GitHub Actions**. Allow the `github-pages` environment to deploy release tags as well as `main`; an environment restricted to `main` alone will block a `release: published` event.

The default local identity is `Developer ID Application: Len Knoche (N5ZXADUHPB)`. Public configuration overrides are `NATIVEAGENT_SIGNING_IDENTITY`, `NATIVEAGENT_NOTARY_PROFILE`, `NATIVEAGENT_SPARKLE_ACCOUNT`, and `NATIVEAGENT_GH`. There are no private-key/password environment variables.

## Release an update

1. Edit `NativeAgent/Resources/Info.plist`. Set the human-facing `CFBundleShortVersionString` (e.g. `0.5.1`) and increase integer `CFBundleVersion` (e.g. `10`). Build numbers must exceed every previous release, including drafts. Never reuse an existing version tag.
2. Review and commit all intended changes on `main`. The script never stages or commits for you and refuses a dirty checkout.
3. Run:

```sh
bash Scripts/publish-release.sh --publish
```

The command validates credentials and remote history, tests an isolated committed snapshot, builds a universal app, signs nested helpers and the app with hardened runtime, submits to Apple's notary service, requires `Accepted`, staples and verifies the ticket, and checks Gatekeeper. Only then does it ZIP and Sparkle-sign the final bytes. The feed and archive signatures are independently verified with the embedded public key. No provider executable is launched by the release process.

It atomically pushes `main` and `vVERSION-build.BUILD` without force, uploads all assets to a draft release, then publishes it. GitHub Actions verifies the signatures and metadata before deploying the unchanged signed feed and static site. This is asynchronous: check the **Tests and signed release deployment** workflow in GitHub Actions before announcing the release. No signing secret is needed by that workflow.

```sh
bash Scripts/publish-release.sh --check
bash Scripts/publish-release.sh --dry-run
```

`--check` performs authenticated read-only preflight (and may resolve local dependencies/fetch Git refs). `--dry-run` is the default: it performs real signing and uploads the app to **Apple for notarization**, but does not push source, create tags, publish releases, or deploy Pages. Output is kept under ignored `dist/release-TAG.XXXXXX/` for inspection. A publish run builds again; it never silently reuses a dry-run artifact.

## Failures and recovery

- Build, test, identity, key mismatch or notarization failures stop before any GitHub writes. A failed notarization retains `notarization.json`, including the submission ID. Retrieve details with `xcrun notarytool log SUBMISSION_ID --keychain-profile NativeAgent-Notary`.
- If Apple takes a long time, leave the command running. An interrupted run does not publish. Its already-uploaded notarization submission may still finish at Apple.
- If a push succeeded but release upload failed, the tag is retained and any incomplete release remains a draft. Do not force-push/delete/reuse that version. Inspect the saved artifacts and GitHub state, then either manually finish that exact verified draft or increment the build and rerun. A new run will refuse the existing tag.
- If release publication succeeded but Pages deployment failed, fix the workflow/environment permissions and run it manually with the published tag. This redeploys existing signed assets without keys or rebuilding. Older releases cannot replace the current latest feed.
- Concurrent local releases are blocked by `dist/local-release.lock`. After a crash, first confirm no release process is running, then remove that **empty directory only** with `rmdir dist/local-release.lock`.
- Output directories are intentionally retained; remove reviewed build artifacts manually when no longer needed. Do not edit a signed archive or appcast: any byte change invalidates the signature.

## Installing the first update-enabled app

Older NativeAgent builds do not contain Sparkle. Install the first signed release manually by extracting the ZIP and moving NativeAgent.app into Applications. Thereafter the app checks about hourly and can install verified updates on quit. Use NativeAgent → Check for Updates for a manual check. A first-launch download confirmation can still appear for correctly signed/notarized software; never override a malware warning.

The script automates release creation, not approval of provider access or commercial distribution rights. Signing/notarization does not establish provider entitlement. Protect GitHub maintainer access and keep signing-key backups private.
