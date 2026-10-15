# Release and signing decisions

Recorded October 15, 2026. These apply through v1 and to any future build machine.

## Who does what
- Code Lead plans, implements, and merges milestone PRs after Repo Guard's security sign-off and Machine Keeper's Mac test. Karim gave standing merge and release permission through v1.
- Repo Guard reviews every milestone and runs a final security pass before release.
- Machine Keeper runs signing, notarization, and Sparkle key work on the Mac.
- Code Lead picks the license provider and price and runs the trademark check for umbilical and umb.

## Signing and notarization
- Developer ID Application certificate lives in the login Keychain on the signing Mac.
- The App Store Connect API key file used by `notarytool` lives on the signing Mac with permissions 600 (file) and 700 (folder). genv sets the identity and key variables.
- Signing commands read keys from the Keychain or genv. They never print keys or pass them on a command line. Logs posted anywhere are redacted.
- Keys are never copied to CI, cloud agents, the umbilical repo, or chat.
- Planned: the App Store Connect API key is committed to Karim's local genv config repo, backed up to his self-hosted encrypted git machine and an encrypted Time Machine drive, so the Mac is not the only copy. Machine Keeper adds the safeguards first (exact-filename scanner allowlist, pre-push check that only allows that machine).

### Shared with other apps

The Developer ID certificate and the App Store Connect API key are shared with the genv and PeaProxy releases. umbilical signs and notarizes on the Mac, while genv and PeaProxy sign in GitHub Actions with copies stored as `MACOS_*` secrets in each repo's `release` environment (only `v*` tags can use them), so a rotation also means re-uploading them with `scripts/set-macos-signing-secrets.sh --env release`. Changing, rotating, revoking or moving any of them can break signing for those apps too. Before any such change, check the genv and PeaProxy release steps and test a signed build of each. The Sparkle key is umbilical's own and is not shared.

## Sparkle update key
- Generated near release on the signing Mac with Sparkle's `generate_keys`, stored in the Keychain. Only the public key ships in the app.
- Backup (planned): `generate_keys -x` writes the private key as plain text. Write it into a folder readable only by Karim's account, then commit it to the genv config repo under the same safeguards as the App Store Connect key, and delete the plain-text file. It must never land in Downloads or iCloud.
- Losing this key means installed copies stop accepting updates, so the backup is required before any release.

## Before release
- Repo Guard verifies the shipped dmg's notarization and the update feed's signatures, rechecks the App Sandbox decision, reviews the server-side license check, and scans the release tag for secrets and vulnerable dependencies.

## Second signing machine (planned)
A Mac Studio is joining the setup in one to two months. Machine Keeper will add it to genv so development, signing, and notarization work there too. To get there:
- Install the Developer ID certificate on it (export from the Keychain as a password-protected .p12, import, delete the .p12).
- Restore the Sparkle private key from the genv config repo, using the same no-plaintext-left-behind steps.
- Copy the App Store Connect key with the same 600 and 700 permissions.
- Move the .p12 and the App Store Connect key only through the genv config repo on Karim's self-hosted machine or a direct encrypted transfer, never iCloud Drive, email, or chat, and delete every temporary copy afterward.
- Run a test notarization on the new machine before trusting it.
- Confirm both machines produce builds that verify with the same Sparkle public key.
