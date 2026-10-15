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
- Keys are never copied to CI, cloud agents, the repo, or chat.

## Sparkle update key
- Generated near release on the signing Mac with Sparkle's `generate_keys`, stored in the Keychain. Only the public key ships in the app.
- Backup: `generate_keys -x` writes the private key as plain text. Write it into a folder readable only by Karim's account, store it in the password manager immediately, then delete the file. It must never land in Downloads, iCloud, or Time Machine first.
- Losing this key means installed copies stop accepting updates, so the backup is required before any release.

## Before release
- Repo Guard verifies the shipped dmg's notarization and the update feed's signatures, rechecks the App Sandbox decision, reviews the server-side license check, and scans the release tag for secrets and vulnerable dependencies.

## Second signing machine (planned)
A Mac Studio is joining the setup in one to two months. Machine Keeper will add it to genv so development, signing, and notarization work there too. To get there:
- Install the Developer ID certificate on it (export from the Keychain as a password-protected .p12, import, delete the .p12).
- Restore the Sparkle private key from the password manager backup using the same no-plaintext-left-behind steps.
- Copy the App Store Connect key with the same 600 and 700 permissions.
- Confirm both machines produce builds that verify with the same Sparkle public key.
