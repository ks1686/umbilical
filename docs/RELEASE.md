# Release and signing decisions

Recorded October 15, 2026. Updated the same day: umbilical is signed on the signing Mac. GitHub Actions does not receive the Developer ID certificate, the App Store Connect API key, or the Sparkle private key.

## Who does what
- Code Lead plans, implements, and merges milestone PRs after Repo Guard's security sign-off and Machine Keeper's Mac test. Karim gave standing merge and release permission through v1.
- Repo Guard reviews every milestone and runs a final security pass before release.
- Machine Keeper keeps the Developer ID certificate, the App Store Connect API key, and the Sparkle private key on the signing Mac. They live in the login Keychain and under `~/.config/genv`. This repo does not copy them into GitHub Actions.
- genv and PeaProxy may still sign in GitHub Actions. umbilical must not.
- Code Lead picked Polar's public license-key API and the price. The trademark check for umbilical and umb is still open.

## On the Mac

`scripts/release/publish.sh`, also available as `just release vX.Y.Z`, is the only publisher. It refuses to run when `GITHUB_ACTIONS` is set. It also stops, without reading the values, if the environment already contains the Developer ID certificate, that certificate's password, the App Store Connect API key, or the Sparkle private key.

| Material | Where it lives |
| --- | --- |
| Developer ID Application certificate | login Keychain. The script unlocks that keychain without putting a password on the command line, then requires exactly one valid Developer ID Application identity. It does not import a `.p12` and it does not create a temporary keychain. |
| App Store Connect API key | A `notarytool` keychain profile, or local files under `~/.config/genv/notarize/`. |
| Sparkle private key | `~/.config/genv/sparkle/umbilical.key`, mode 600 or 400. |

Notary files, used when no keychain profile is set:

- `~/.config/genv/notarize/keychain-profile` is optional. One line, the profile name. If this file exists, or `NOTARY_KEYCHAIN_PROFILE` is set, `notarytool` uses `--keychain-profile`.
- Otherwise the script uses `~/.config/genv/notarize/AuthKey.p8` (mode 600 or 400), `~/.config/genv/notarize/key-id`, and `~/.config/genv/notarize/issuer-id`.

These overrides are a path or an id, not the key bytes: `NOTARY_KEY_PATH`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`. `SPARKLE_ED_KEY_FILE` is an override path for the Sparkle private key. `sign_update` reads that file with `--ed-key-file`. The script does not copy the key into a temp file and does not delete the real file.

The signing Mac's config directory is local only. GitHub `ks1686/genv` is the public Go genv CLI, a separate project.

## Public

These are not secrets:

- `SUPublicEDKey` is `wMhJbYoJtpde3xrtBBL1neu9PM5giL3OnYmE7C04OFY=`. It is in `App/Info.plist`. The Mac script derives the public key from the local Sparkle private key and fails if they differ.
- `POLAR_ORGANIZATION_ID` is the Polar organization UUID. It is not an access token. Set it in the environment or in `Config/Licensing.local.xcconfig` (gitignored). The script fails if it is empty or not a UUID. Pull requests and the unsigned dry run do not set it.
- The Homebrew cask draft is `docs/homebrew/umbilical.rb`. The script uploads `umbilical.rb` on the GitHub release with the real version and SHA-256. Copy that asset into `ks1686/homebrew-tap` by hand. Do not push the tap from this repo.

## What the Mac script runs

Run it on the signing Mac from a clean checkout of `ks1686/umbilical`. `HEAD` must be the tag, and the tag must already be on `origin`. `gh auth status` must succeed. The script uses that login. It does not read `GH_TOKEN`.

```bash
just release v0.0.1
```

`scripts/release/publish.sh v0.0.1` is the same command. The tag must look like `vMAJOR.MINOR.PATCH`. The version stamped on the app is the tag without the leading `v`.

1. Fail if `POLAR_ORGANIZATION_ID` is empty or not a UUID, or if the local Sparkle private key does not match `SUPublicEDKey`.
2. Write `Config/Licensing.local.xcconfig` (gitignored) and stamp `CFBundleShortVersionString` and `CFBundleVersion` from the tag.
3. Read the Developer ID Application identity from the login Keychain.
4. Build a Release app. Xcode signs that build ad hoc. `scripts/copy-bundled-aria2.sh` and `scripts/copy-bundled-yt-dlp.sh` still refuse a Release build when `helpers/bin/aria2c` or `helpers/bin/yt-dlp` is missing. Those scripts receive the Developer ID and pass `--timestamp` when the identity is not `-`.
5. `scripts/release/sign-bundle.sh` is the signature that ships. It signs aria2c and yt-dlp with the Developer ID identity, `--options runtime`, and `--timestamp`. yt-dlp gets `helpers/yt-dlp.entitlements` and no other entitlement file.
6. The same pass signs Sparkle's `Downloader.xpc`, `Installer.xpc`, `Updater.app`, and `Autoupdate`, then `Sparkle.framework`, with the same identity, hardened runtime, and a timestamp. Existing entitlements are kept, and `com.apple.security.get-task-allow` is removed if it is present.
7. It then signs the app with `App/umbilical.entitlements`, hardened runtime, and a timestamp.
8. Run `scripts/check-no-get-task-allow.sh` and `scripts/ci/yt-dlp-version.sh`.
9. Build a dmg with `hdiutil` (`umbilical.app` plus an `/Applications` symlink), sign the dmg with `--timestamp`, and do not pass `--options runtime` on the dmg.
10. Notarize with `notarytool` using the keychain profile or the local API key, staple, then run `stapler validate` and `spctl --assess --type open --context context:primary-signature`.
11. Sign the stapled dmg with Sparkle `sign_update`, merge it into `appcast.xml`, and sign that file with `sign_update` as well. Stapling changes the file bytes, so the signature is made after the staple.
12. Upload `umbilical-VERSION.dmg`, `umbilical-VERSION.dmg.sha256`, `appcast.xml`, and `umbilical.rb` to the GitHub release for that tag. The cask is not pushed to `ks1686/homebrew-tap`.

The script does not print the API key or the Sparkle private key. `sign_update` does not use the deprecated `-s` flag. If `sign_update` fails, its output is discarded, because a bad key can be echoed by that tool.

`gpg`, `pkg-config`, `xcodegen`, `gh`, `python3`, `codesign`, `xcrun`, `hdiutil`, and `security` must already be installed. The script does not install them.

## Unsigned dry run

`workflow_dispatch` on `.github/workflows/release.yml` builds a Release app with the ad hoc identity `-`, runs the helper and `get-task-allow` checks, and uploads `umbilical-dry-run.dmg` plus its SHA-256 as a workflow artifact. Pushing a version tag does not start that workflow. The workflow has no GitHub environment and no signing secrets. Pull request CI stays on `.github/workflows/ci.yml` and is also unsigned.

Ad hoc signatures cannot take `--timestamp`. Debug builds use `App/umbilical-debug.entitlements`, which sets `com.apple.security.cs.disable-library-validation` so an ad hoc Sparkle framework can load. Release entitlements do not set that key. Library validation stays on for the notarized app, and Sparkle is re-signed with the same Developer ID.

## Sparkle

Sparkle 2.9.6 is linked through Swift Package Manager (`exactVersion` in `project.yml`). The appcast is hosted on GitHub Releases, not GitHub Pages:

`https://github.com/ks1686/umbilical/releases/latest/download/appcast.xml`

That URL stays stable. GitHub redirects it to the `appcast.xml` asset on the latest non-draft release. The dmg URL inside each item is the versioned download URL, so an update does not follow "latest" for the archive itself. Each tag uploads an appcast that keeps older items and replaces an item with the same `sparkle:version`. Deleting the latest release removes the feed until another release carries `appcast.xml`.

`SUPublicEDKey` in `App/Info.plist` is `wMhJbYoJtpde3xrtBBL1neu9PM5giL3OnYmE7C04OFY=`. `SUEnableAutomaticChecks` is true. The scheduled interval is 86400 seconds. `SUVerifyUpdateBeforeExtraction` and `SURequireSignedFeed` are true, so Sparkle checks the archive signature before extracting it and requires the appcast signature `sign_update` embeds. Automatic checks are on. `SUAutomaticallyUpdate` is left unset, so Sparkle does not install updates silently.

The menu bar menu and the app menu both have Check for Updates. It calls `SPUStandardUpdaterController.checkForUpdates`.

`generate_keys -x` writes one base64 line. Current Sparkle keys decode to a 32 byte seed. Older exports decode to 96 bytes. Save that line as `~/.config/genv/sparkle/umbilical.key` with mode 600 or 400. The Mac script derives the public key and fails if it is not `SUPublicEDKey`.

The private key still needs a backup before the first tag. Put the file in a folder readable only by Karim's account, and commit it to the local genv config repo under the same safeguards as the App Store Connect key. It must never land in Downloads, iCloud, this repo, GitHub Actions, or chat. Losing it means installed copies stop accepting updates. The key is umbilical's. It is not shared with genv or PeaProxy.

The tool used to sign is `bin/sign_update` from `Sparkle-for-Swift-Package-Manager.zip` 2.9.6, checksum `8d5fb41d960b43f4a68aa14126bf62b098544ec8d191cdcc73eb14e63a8e7606`.

## Signing and notarization
- The Developer ID Application certificate lives in the login Keychain on the signing Mac. The publish script reads it from there. It does not import a `.p12`.
- The App Store Connect API key stays in the login Keychain as a `notarytool` profile, or as a mode 600 file under `~/.config/genv/notarize/`. GitHub Actions does not get a copy.
- Logs posted anywhere are redacted. Do not paste key material into chat or into this repo.
- Planned: the App Store Connect API key and the Sparkle private key are committed to Karim's local genv config repo, backed up to his self-hosted encrypted git machine and an encrypted Time Machine drive, so the Mac is not the only copy. Machine Keeper adds the safeguards first (exact-filename scanner allowlist, pre-push check that only allows that machine).

### Shared with other apps

The Developer ID certificate and the App Store Connect API key are shared with the genv and PeaProxy releases. Those apps may still sign in GitHub Actions. umbilical must not. Changing, rotating, revoking, or moving either one can break signing for those apps too. Before any such change, check the genv and PeaProxy release steps and test a signed build of each. Do not add their Actions secrets to this repo.

## yt-dlp helper entitlements

The pinned yt-dlp macOS binary is a PyInstaller build. It unpacks a Python runtime at launch. Hardened runtime needs these three entitlements on that helper:

- `com.apple.security.cs.disable-library-validation`, so the extracted libpython can load
- `com.apple.security.cs.allow-unsigned-executable-memory`, for libffi's writable executable mapping
- `com.apple.security.cs.allow-jit`, for `MAP_JIT` on arm64

These keys are limited to `helpers/yt-dlp.entitlements`. `scripts/copy-bundled-yt-dlp.sh` applies that file when it signs the helper. The post-build sign uses the same file. App entitlements are unchanged.

`com.apple.security.cs.allow-dyld-environment-variables` is not set, so DYLD injection stays blocked.

The residual risk is a same-user process swapping libraries PyInstaller extracts into its temporary directory. That gives nothing beyond that user's existing access.

## License checks
- The app calls Polar's public customer-portal license-key validate, activate, and deactivate routes. The body includes the organization id. There is no organization access token in the app, this repo, or CI.
- The organization id is build configuration (`Config/Licensing.xcconfig` and a gitignored local file). It is not a secret, and it is not an access token. See `docs/LICENSING.md`.
- Transport security is HTTPS to `api.polar.sh`. The app refuses redirects. Activation replies are not separately signed.
- The Keychain cache is bound to this Mac and this key. A copied record does not grant offline use.

## Homebrew cask

`docs/homebrew/umbilical.rb` is a draft for `ks1686/homebrew-tap`. It is `cask "umbilical"`, with a pinned `sha256`, `auto_updates true`, `depends_on macos: ">= :sonoma"` (the app's minimum is macOS 14.0), and a `zap` stanza. The zero sha256 in that file is a placeholder. The Mac script uploads `umbilical.rb` on the GitHub release with the real version and the dmg's SHA-256. Copy that asset into the tap by hand after `brew audit --cask` and `brew style`. Do not push the draft from this repo, and do not expect the script to push it.

## Checklist before a tag

1. The Polar product exists ($9.99, one time, activation limit 1, no expiry). Buyers deactivate instances in Polar.
2. `POLAR_ORGANIZATION_ID` is that organization's UUID, in the environment or in `Config/Licensing.local.xcconfig`.
3. The login Keychain has exactly one Developer ID Application identity.
4. Notarization uses the keychain profile or the local files under `~/.config/genv/notarize/`.
5. `~/.config/genv/sparkle/umbilical.key` is the `generate_keys -x` export for `SUPublicEDKey`, mode 600 or 400, and the genv config repo has the backup.
6. `gh auth status` succeeds on the signing Mac.
7. `main` is the commit you mean to ship. The tag is `vMAJOR.MINOR.PATCH` and it is already on origin. The working tree is clean.
8. Repo Guard has reviewed signing, the appcast, the license check, the cask draft, App Sandbox, and the tag for secrets.
9. If this repo's GitHub `release` environment still holds signing material from an earlier draft, delete those secrets in GitHub settings. The workflows do not read them.

## Checklist after the script

1. The Mac script finished, including `stapler validate` and `spctl`.
2. The release has the dmg, the `.sha256` file, `appcast.xml`, and `umbilical.rb`.
3. The downloaded dmg's SHA-256 matches the `.sha256` asset.
4. `codesign` on the app shows Developer ID, hardened runtime, and a timestamp. Sparkle's XPC services and `Autoupdate` do too. yt-dlp still has only `helpers/yt-dlp.entitlements`.
5. `spctl` and `stapler validate` pass on the downloaded dmg.
6. A second Mac sees the update from Check for Updates, or from a launch after the last check time is cleared.
7. Copy `umbilical.rb` into `ks1686/homebrew-tap` and run the cask checks on the Mac.

## Before release
- Repo Guard verifies the shipped dmg's notarization and the update feed's signatures, rechecks the App Sandbox decision, reviews the Polar license check, and scans the release tag for secrets and vulnerable dependencies.

## Second signing machine (planned)
A Mac Studio is joining the setup in one to two months. Machine Keeper will add it to genv so development and key backup work there too. The Mac script remains the publisher. To get there:
- Install the Developer ID certificate on it (export from the Keychain as a password-protected .p12, import, delete the .p12).
- Restore `~/.config/genv`, including the Sparkle private key and the App Store Connect key, using the same no-plaintext-left-behind steps.
- Move the .p12 and the App Store Connect key only through the genv config repo on Karim's self-hosted machine or a direct encrypted transfer, never iCloud Drive, email, or chat, and delete every temporary copy afterward.
- Do not put the certificate, the API key, or the Sparkle private key in this repo's GitHub Actions secrets. If the shared certificate or API key changes, update genv and PeaProxy, which may still sign in Actions, and notarize a test build of each before trusting the new material.
- Confirm the restored Sparkle key's public half is still `SUPublicEDKey`.
