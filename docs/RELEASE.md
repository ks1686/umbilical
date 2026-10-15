# Release and signing decisions

Recorded October 15, 2026. The tag workflow was added the same day.
These apply through v1 and to any future build machine.

## Who does what
- Code Lead plans, implements, and merges milestone PRs after Repo Guard's security sign-off and Machine Keeper's Mac test. Karim gave standing merge and release permission through v1.
- Repo Guard reviews every milestone and runs a final security pass before release.
- Machine Keeper keeps the Developer ID certificate, the App Store Connect API key, and the Sparkle private key. The copies used by GitHub Actions live in this repo's `release` environment.
- Code Lead picked Polar's public license-key API and the price. The trademark check for umbilical and umb is still open.

## Release environment

The signed job in `.github/workflows/release.yml` sets `environment: release`.
It runs only for a push of a `v*` tag. `workflow_dispatch` builds an unsigned
dmg and does not select that environment. Pull requests do not run the
release workflow.

In GitHub, the `release` environment's deployment branches should allow only
tags that match `v*`. That is the same rule genv and PeaProxy use. The
workflow condition is not a substitute for that setting.

| Name | Kind | Value |
| --- | --- | --- |
| `MACOS_SIGN_P12` | secret | base64 of the Developer ID Application `.p12` |
| `MACOS_SIGN_PASSWORD` | secret | password for that `.p12` |
| `MACOS_NOTARY_KEY` | secret | base64 of the App Store Connect API key `.p8` |
| `MACOS_NOTARY_KEY_ID` | secret | App Store Connect key id |
| `MACOS_NOTARY_ISSUER_ID` | secret | App Store Connect issuer id |
| `SPARKLE_ED_PRIVATE_KEY` | secret | file contents from Sparkle `generate_keys -x` |
| `POLAR_ORGANIZATION_ID` | secret or variable | Polar organization UUID |

`POLAR_ORGANIZATION_ID` is not an access token. Prefer a release-environment
variable. The workflow also accepts a secret of the same name. If both are
set, the secret wins (`secrets.POLAR_ORGANIZATION_ID || vars.POLAR_ORGANIZATION_ID`).
The job fails when the value is empty or is not a UUID.

The five `MACOS_*` names match genv and PeaProxy. Rotate them with
`scripts/set-macos-signing-secrets.sh --env release` in those repos, then
confirm an umbilical tag still notarizes. `SPARKLE_ED_PRIVATE_KEY` and
`POLAR_ORGANIZATION_ID` belong to umbilical only.

Set the Sparkle secret from the exported file, not from a command-line
argument:

```bash
gh secret set SPARKLE_ED_PRIVATE_KEY --repo ks1686/umbilical --env release < sparkle-ed-private-key
```

Delete that file from the Mac after the backup copy is in the genv config
repo. Do not commit it here.

## What a tag runs

Pushing `vMAJOR.MINOR.PATCH` (for example `v0.0.1`) on this repo runs the
signed job:

1. Fail if `POLAR_ORGANIZATION_ID` is empty or not a UUID, or if `SPARKLE_ED_PRIVATE_KEY` does not match `SUPublicEDKey`.
2. Write `Config/Licensing.local.xcconfig` (gitignored) and stamp `CFBundleShortVersionString` and `CFBundleVersion` from the tag.
3. Import the Developer ID certificate into a temporary keychain.
4. Build a Release app. Xcode signs that build ad hoc. `scripts/copy-bundled-aria2.sh` and `scripts/copy-bundled-yt-dlp.sh` still refuse a Release build when `helpers/bin/aria2c` or `helpers/bin/yt-dlp` is missing. Those scripts receive the Developer ID and pass `--timestamp` when the identity is not `-`.
5. `scripts/release/sign-bundle.sh` is the signature that ships. It signs aria2c and yt-dlp with the Developer ID identity, `--options runtime`, and `--timestamp`. yt-dlp gets `helpers/yt-dlp.entitlements` and no other entitlement file.
6. The same pass signs Sparkle's `Downloader.xpc`, `Installer.xpc`, `Updater.app`, and `Autoupdate`, then `Sparkle.framework`, with the same identity, hardened runtime, and a timestamp. Existing entitlements are kept, and `com.apple.security.get-task-allow` is removed if it is present.
7. It then signs the app with `App/umbilical.entitlements`, hardened runtime, and a timestamp.
8. Run `scripts/check-no-get-task-allow.sh` and `scripts/ci/yt-dlp-version.sh`.
9. Build a dmg with `hdiutil` (`umbilical.app` plus an `/Applications` symlink), sign the dmg, and timestamp it.
10. Notarize with `notarytool` using the App Store Connect API key, staple, then run `stapler validate` and `spctl --assess --type open --context context:primary-signature`.
11. Sign the stapled dmg with Sparkle `sign_update`, merge it into `appcast.xml`, and sign that file with `sign_update` as well.
12. Upload `umbilical-VERSION.dmg`, `umbilical-VERSION.dmg.sha256`, `appcast.xml`, and `umbilical.rb` to the GitHub release. The cask is not pushed to `ks1686/homebrew-tap`.

The version is the tag without the leading `v`. Tags that are not
`vMAJOR.MINOR.PATCH` fail before signing.

`security import` and `security set-key-partition-list` take the `.p12`
password as an argument because those tools have no file option. The
workflow does not print the password, the `.p12`, the API key, or the
Sparkle private key. `sign_update` reads the Sparkle key from a mode 0600
file (`--ed-key-file`). It does not use the deprecated `-s` flag. If
`sign_update` fails, its output is discarded, because a bad key can be
echoed by that tool.

## Unsigned dry run

`workflow_dispatch` on `.github/workflows/release.yml` builds a Release app
with the ad hoc identity `-`, runs the helper and `get-task-allow` checks,
and uploads `umbilical-dry-run.dmg` plus its SHA-256 as a workflow artifact.
It does not import certificates, notarize, or read the release environment.
Pull request CI stays on `.github/workflows/ci.yml` and is also unsigned.

Ad hoc signatures cannot take `--timestamp`. Debug builds use
`App/umbilical-debug.entitlements`, which sets
`com.apple.security.cs.disable-library-validation` so an ad hoc Sparkle
framework can load. Release entitlements do not set that key. Library
validation stays on for the notarized app, and Sparkle is re-signed with
the same Developer ID.

## Sparkle

Sparkle 2.9.6 is linked through Swift Package Manager (`exactVersion` in
`project.yml`). The appcast is hosted on GitHub Releases, not GitHub Pages:

`https://github.com/ks1686/umbilical/releases/latest/download/appcast.xml`

That URL stays stable. GitHub redirects it to the `appcast.xml` asset on
the latest non-draft release. The dmg URL inside each item is the versioned
download URL, so an update does not follow "latest" for the archive itself.
Each tag uploads an appcast that keeps older items and replaces an item
with the same `sparkle:version`. Deleting the latest release removes the
feed until another release carries `appcast.xml`.

`SUPublicEDKey` in `App/Info.plist` is
`wMhJbYoJtpde3xrtBBL1neu9PM5giL3OnYmE7C04OFY=`.
`SUEnableAutomaticChecks` is true. The scheduled interval is 86400 seconds.
`SUVerifyUpdateBeforeExtraction` and `SURequireSignedFeed` are true, so
Sparkle checks the archive signature before extracting it and requires the
appcast signature `sign_update` embeds. Automatic checks are on.
`SUAutomaticallyUpdate` is left unset, so Sparkle does not install updates
silently.

The menu bar menu and the app menu both have Check for Updates. It calls
`SPUStandardUpdaterController.checkForUpdates`.

`SPARKLE_ED_PRIVATE_KEY` is the text written by `generate_keys -x`: one
base64 line. Current Sparkle keys decode to a 32 byte seed. Older exports
decode to 96 bytes. The workflow derives the public key and fails if it is
not `SUPublicEDKey`.

The private key still needs a backup before the first tag. `generate_keys -x`
writes it as plain text. Put that file in a folder readable only by Karim's
account, commit it to the genv config repo under the same safeguards as the
App Store Connect key, and delete the plain-text file. It must never land
in Downloads, iCloud, this repo, or chat. Losing it means installed copies
stop accepting updates. The key is umbilical's. It is not shared with genv
or PeaProxy.

The tool used to sign is `bin/sign_update` from
`Sparkle-for-Swift-Package-Manager.zip` 2.9.6, checksum
`8d5fb41d960b43f4a68aa14126bf62b098544ec8d191cdcc73eb14e63a8e7606`.

## Signing and notarization
- The Developer ID Application certificate still lives in the login Keychain on the signing Mac. The tag workflow imports a `.p12` copy into a temporary keychain and deletes that keychain at the end of the job.
- The App Store Connect API key file used by `notarytool` on the Mac stays mode 600, in a mode 700 folder. The GitHub copy is `MACOS_NOTARY_KEY`.
- Logs posted anywhere are redacted. Do not paste key material into chat or into this repo.
- Planned: the App Store Connect API key and the Sparkle private key are committed to Karim's local genv config repo, backed up to his self-hosted encrypted git machine and an encrypted Time Machine drive, so the Mac is not the only copy. Machine Keeper adds the safeguards first (exact-filename scanner allowlist, pre-push check that only allows that machine).

### Shared with other apps

The Developer ID certificate and the App Store Connect API key are shared
with the genv and PeaProxy releases. Those apps sign in GitHub Actions with
the same `MACOS_*` secret names in each repo's `release` environment.
Changing, rotating, revoking, or moving any of them can break signing for
those apps too. Before any such change, check the genv and PeaProxy release
steps and test a signed build of each.

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

`docs/homebrew/umbilical.rb` is a draft for `ks1686/homebrew-tap`. It is
`cask "umbilical"`, with a pinned `sha256`, `auto_updates true`,
`depends_on macos: ">= :sonoma"` (the app's minimum is macOS 14.0), and a
`zap` stanza. The zero sha256 in that file is a placeholder. The tag
workflow uploads `umbilical.rb` on the GitHub release with the real version
and the dmg's SHA-256. Copy that asset into the tap by hand after
`brew audit --cask` and `brew style`. Do not push the draft from this repo,
and do not expect the workflow to push it.

## Checklist before a tag

1. The Polar product exists ($9.99, one time, 3 activations, no expiry).
2. `POLAR_ORGANIZATION_ID` is set in the `release` environment and is that organization's UUID.
3. The five `MACOS_*` secrets are the current Developer ID and App Store Connect key.
4. `SPARKLE_ED_PRIVATE_KEY` is the `generate_keys -x` export for `SUPublicEDKey`, and the genv config repo has the backup.
5. The deployment branch rule on the `release` environment allows only `v*` tags.
6. `main` is the commit you mean to ship. The tag is `vMAJOR.MINOR.PATCH`.
7. Repo Guard has reviewed signing, the appcast, the license check, the cask draft, App Sandbox, and the tag for secrets.

## Checklist after the workflow

1. The signed job succeeded, including `stapler validate` and `spctl`.
2. The release has the dmg, the `.sha256` file, `appcast.xml`, and `umbilical.rb`.
3. The downloaded dmg's SHA-256 matches the `.sha256` asset.
4. `codesign` on the app shows Developer ID, hardened runtime, and a timestamp. Sparkle's XPC services and `Autoupdate` do too. yt-dlp still has only `helpers/yt-dlp.entitlements`.
5. `spctl` and `stapler validate` pass on the downloaded dmg.
6. A second Mac sees the update from Check for Updates, or from a launch after the last check time is cleared.
7. Copy `umbilical.rb` into `ks1686/homebrew-tap` and run the cask checks on the Mac.

## Before release
- Repo Guard verifies the shipped dmg's notarization and the update feed's signatures, rechecks the App Sandbox decision, reviews the Polar license check, and scans the release tag for secrets and vulnerable dependencies.

## Second signing machine (planned)
A Mac Studio is joining the setup in one to two months. Machine Keeper will add it to genv so development and key backup work there too. The tag workflow remains the publisher. To get there:
- Install the Developer ID certificate on it (export from the Keychain as a password-protected .p12, import, delete the .p12).
- Restore the Sparkle private key from the genv config repo, using the same no-plaintext-left-behind steps.
- Copy the App Store Connect key with the same 600 and 700 permissions.
- Move the .p12 and the App Store Connect key only through the genv config repo on Karim's self-hosted machine or a direct encrypted transfer, never iCloud Drive, email, or chat, and delete every temporary copy afterward.
- If the certificate or API key changes, update the `MACOS_*` secrets in this repo's `release` environment as well as genv and PeaProxy, and notarize a test tag before trusting the new material.
- Confirm the restored Sparkle key's public half is still `SUPublicEDKey`.
